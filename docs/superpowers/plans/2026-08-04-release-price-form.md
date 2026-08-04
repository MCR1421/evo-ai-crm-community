# Price-Release Form Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the 1-click price-release link in the price-gate private note with a form where the seller picks which products to send, edits the price/discount per product, and confirms — the message the customer receives is built exactly from what the seller submits, sent directly (not through the bot/LLM).

**Architecture:** Two repos change. `evo-ai-processor-community` (Python): the guardrail that registers a pending price-gate quote in Redis now includes each product's sale price and cost price (previously it only included name/code/in-stock), and the release link embedded in the private note points at a new form URL instead of the old instant-release URL. `evo-ai-crm-community` (Rails): a new `GET /price_gate/release_form` renders that pending quote as an editable form (no side effects); a new `POST /price_gate/release_form` validates the seller's selections, builds one message listing the chosen products/prices, posts it to the conversation via the same service the bot uses for outgoing messages (`AgentBots::MessageCreator`, called directly — bypassing the bot/LLM and its normal pending-only eligibility check via `force: true`), then releases and clears the price gate.

**Tech Stack:** Python 3.11 / FastAPI / httpx (processor), Ruby on Rails (API-only controller) / Redis via `PriceGateService` (crm), vanilla JS (no framework) for the discount-field sync on the form, RSpec (Rails tests), pytest + pytest-asyncio (Python tests).

## Global Constraints

- No login for the release form — same auth as today: `internal_secret` as a query param (link click) or `X-Internal-Secret` header, checked by the existing `verify_internal_secret` before_action.
- `GET /price_gate/release_form` must have zero side effects (state only changes on POST) — this fixes a real risk in the old link-based flow, where a bare GET released the gate and could fire from a link-preview bot.
- Price IS sent to the customer through this flow once the seller explicitly picks it on the form — this page is the deliberate, seller-controlled exception to the bot's "never say the price" rule described in `docs/superpowers/specs/2026-08-04-release-price-form-design.md`. Cost price (`preco_custo`) is shown to the seller for margin reference only and must never appear in the outgoing customer message.
- The outgoing message is sent via `AgentBots::MessageCreator#create_bot_reply(content, conversation, force: true)` — never raw `Message.create!`, never by re-triggering the bot/LLM via a `[gate_liberado]` resume message.
- The old `GET /price_gate/release_link` route and `PriceGateController#release_from_link` action stay in the codebase, just no longer linked from the private note. Do not delete them.
- Currency in both the form and the outgoing message is formatted pt-BR (`R$ 1.500,00`) — use `ActiveSupport::NumberHelper.number_to_currency(value, unit: 'R$ ', separator: ',', delimiter: '.')` on the Ruby side, the existing `_format_brl` helper on the Python side.
- No product stays "pending" after a POST submit — whether selected or not, the whole quote is cleared (`gate.clear!`) once the seller submits the form.

---

## File Structure

**evo-ai-processor-community** (`src/services/adk/runners/standard_runner.py`, modify only — no new files):
- `_register_pending_price_gate` — quote payload gains `preco_venda`/`preco_custo` per product.
- `_build_release_link` — target path changes from `/price_gate/release_link` to `/price_gate/release_form`.

New test file: `tests/unit/services/adk/runners/test_standard_runner_price_gate.py`.

**evo-ai-crm-community**:
- `config/routes.rb` (modify) — 2 new routes.
- `app/controllers/api/v1/internal/price_gate_controller.rb` (modify) — 2 new public actions (`release_form`, `submit_release_form`) + 4 new private helpers (`release_form_html`, `merge_submitted_products`, `build_price_message`, `format_brl`). Reuses the existing private `render_release_link_result` for both the missing-quote case and the POST result page — no new view/presenter class; this stays consistent with how the controller already renders `release_from_link`'s result page inline, and the controller is still a single well-scoped resource (price-gate HTTP actions) even after this grows.
- `spec/requests/api/v1/internal/price_gate_spec.rb` (modify) — new `describe` blocks for both new routes, reusing the file's existing `phone`/`secret`/`before`/`after` setup.

---

## Task 1: Processor — include sale price and cost price in the pending quote

**Files:**
- Modify: `src/services/adk/runners/standard_runner.py:269-281` (inside `_register_pending_price_gate`)
- Test: `tests/unit/services/adk/runners/test_standard_runner_price_gate.py` (new)

**Interfaces:**
- Produces: `_register_pending_price_gate(metadata, conv_id, product_details)` now POSTs a `quote.produtos[]` where each item is `{"nome": str, "codigo": str, "em_estoque": bool, "preco_venda": float | None, "preco_custo": float | None}` (previously had no `preco_venda`/`preco_custo` keys at all). Consumed by Task 4/5 on the Rails side, which reads this exact JSON shape back out of `PriceGateService#pending_quote`.

- [ ] **Step 1: Write the failing test**

Create `tests/unit/services/adk/runners/test_standard_runner_price_gate.py`:

```python
from unittest.mock import patch

import pytest

from src.services.adk.runners.standard_runner import (
    _build_release_link,
    _register_pending_price_gate,
)


class _FakeResponse:
    status_code = 200


class _FakeAsyncClient:
    def __init__(self, captured):
        self._captured = captured

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc_info):
        return False

    async def post(self, url, headers=None, json=None):
        self._captured["url"] = url
        self._captured["headers"] = headers
        self._captured["json"] = json
        return _FakeResponse()


@pytest.mark.asyncio
async def test_register_pending_price_gate_includes_sale_and_cost_price(monkeypatch):
    monkeypatch.setenv("EVO_AI_CRM_URL", "http://evo-crm:3000")
    monkeypatch.setenv("INTERNAL_TOOLS_SECRET", "test-secret")

    metadata = {
        "contact": {"phone_number": "+5522999990000"},
        "agent_bot_id": "bot-1",
    }
    product_details = [
        {
            "code": "803097",
            "name": "Alternador XPTO",
            "price": 450.0,
            "cost": 245.0,
            "stock": 3,
            "link": "http://odoo.example/web#id=1",
        },
        {
            "code": "803112",
            "name": "Motor de partida ABC",
            "price": None,
            "cost": None,
            "stock": 0,
            "link": None,
        },
    ]

    captured = {}
    with patch(
        "src.services.adk.runners.standard_runner.httpx.AsyncClient",
        return_value=_FakeAsyncClient(captured),
    ):
        await _register_pending_price_gate(metadata, "conv-1", product_details)

    produtos = captured["json"]["quote"]["produtos"]
    assert produtos == [
        {
            "nome": "Alternador XPTO",
            "codigo": "803097",
            "em_estoque": True,
            "preco_venda": 450.0,
            "preco_custo": 245.0,
        },
        {
            "nome": "Motor de partida ABC",
            "codigo": "803112",
            "em_estoque": False,
            "preco_venda": None,
            "preco_custo": None,
        },
    ]


def test_build_release_link_points_at_release_form(monkeypatch):
    monkeypatch.setenv("EVO_CRM_PUBLIC_URL", "http://localhost:3020")
    monkeypatch.setenv("INTERNAL_TOOLS_SECRET", "test-secret")

    metadata = {"contact": {"phone_number": "+5522999990000"}}

    link = _build_release_link(metadata)

    assert link is not None
    assert link.startswith(
        "http://localhost:3020/api/v1/internal/price_gate/release_form?"
    )
    assert "internal_secret=test-secret" in link
    assert "phone=%2B5522999990000" in link
```

Create empty package markers if they don't already exist:

```bash
mkdir -p tests/unit/services/adk/runners
touch tests/unit/services/adk/runners/__init__.py
```

- [ ] **Step 2: Deploy current (unmodified) source + new test into the running container, verify the test fails**

```bash
MSYS_NO_PATHCONV=1 docker cp src/services/adk/runners/standard_runner.py evo-crm-community-evo-processor-1:/app/src/services/adk/runners/standard_runner.py
MSYS_NO_PATHCONV=1 docker exec evo-crm-community-evo-processor-1 mkdir -p /app/tests/unit/services/adk/runners
MSYS_NO_PATHCONV=1 docker cp tests/unit/services/adk/runners/__init__.py evo-crm-community-evo-processor-1:/app/tests/unit/services/adk/runners/__init__.py
MSYS_NO_PATHCONV=1 docker cp tests/unit/services/adk/runners/test_standard_runner_price_gate.py evo-crm-community-evo-processor-1:/app/tests/unit/services/adk/runners/test_standard_runner_price_gate.py
MSYS_NO_PATHCONV=1 docker exec evo-crm-community-evo-processor-1 python -m pytest tests/unit/services/adk/runners/test_standard_runner_price_gate.py -v
```

Expected: `test_register_pending_price_gate_includes_sale_and_cost_price` FAILS (assertion error — `produtos` items don't have `preco_venda`/`preco_custo` keys yet). `test_build_release_link_points_at_release_form` also FAILS (URL still has `release_link`, not `release_form` — this is Task 2's change; both tests live in the same file and are expected to both fail here, then both pass after Task 1 + Task 2 are done. That's fine — this task's step 4 only needs to turn the first one green; the second one starts passing once Task 2 lands).

- [ ] **Step 3: Implement the quote payload change**

In `src/services/adk/runners/standard_runner.py`, replace the `if product_details:` block inside `_register_pending_price_gate` (currently lines 269-281):

```python
    if product_details:
        quote = {
            "produtos": [
                {
                    "nome": d.get("name"),
                    "codigo": d.get("code"),
                    "em_estoque": bool(
                        isinstance(d.get("stock"), (int, float)) and d["stock"] > 0
                    ),
                    "preco_venda": d.get("price")
                    if isinstance(d.get("price"), (int, float))
                    else None,
                    "preco_custo": d.get("cost")
                    if isinstance(d.get("cost"), (int, float))
                    else None,
                }
                for d in product_details
            ]
        }
```

- [ ] **Step 4: Redeploy and verify the first test passes**

```bash
MSYS_NO_PATHCONV=1 docker cp src/services/adk/runners/standard_runner.py evo-crm-community-evo-processor-1:/app/src/services/adk/runners/standard_runner.py
MSYS_NO_PATHCONV=1 docker exec evo-crm-community-evo-processor-1 python -m pytest tests/unit/services/adk/runners/test_standard_runner_price_gate.py::test_register_pending_price_gate_includes_sale_and_cost_price -v
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/services/adk/runners/standard_runner.py tests/unit/services/adk/runners/__init__.py tests/unit/services/adk/runners/test_standard_runner_price_gate.py
git commit -m "feat: include sale and cost price in pending price-gate quote"
```

---

## Task 2: Processor — release link points at the new form instead of instant-release

**Files:**
- Modify: `src/services/adk/runners/standard_runner.py:213-235` (`_build_release_link`), `:771-781` (release link anchor text in the guardrail block)
- Test: `tests/unit/services/adk/runners/test_standard_runner_price_gate.py` (already has `test_build_release_link_points_at_release_form` from Task 1 — this task makes it pass)

**Interfaces:**
- Produces: `_build_release_link(metadata)` now returns a URL of the form `{EVO_CRM_PUBLIC_URL}/api/v1/internal/price_gate/release_form?internal_secret=...&phone=...` (was `.../release_link?...`). Consumed by Task 4 on the Rails side, which is the `GET` handler this URL must resolve to.

- [ ] **Step 1: Verify the test already fails (written in Task 1)**

```bash
MSYS_NO_PATHCONV=1 docker exec evo-crm-community-evo-processor-1 python -m pytest tests/unit/services/adk/runners/test_standard_runner_price_gate.py::test_build_release_link_points_at_release_form -v
```

Expected: FAIL (URL still contains `release_link`).

- [ ] **Step 2: Implement the path change**

In `_build_release_link` (`standard_runner.py`), change:

```python
    return (
        f"{base_url}/api/v1/internal/price_gate/release_link"
        f"?internal_secret={quote(secret)}&phone={quote(phone)}"
    )
```

to:

```python
    return (
        f"{base_url}/api/v1/internal/price_gate/release_form"
        f"?internal_secret={quote(secret)}&phone={quote(phone)}"
    )
```

Also update the anchor text in the guardrail block (around line 777) so it reflects that clicking now opens a selection form rather than sending instantly — change:

```python
                            "<strong>Liberar e enviar esse preço pro cliente</strong>"
```

to:

```python
                            "<strong>Escolher o que enviar pro cliente</strong>"
```

- [ ] **Step 3: Redeploy and verify the test passes**

```bash
MSYS_NO_PATHCONV=1 docker cp src/services/adk/runners/standard_runner.py evo-crm-community-evo-processor-1:/app/src/services/adk/runners/standard_runner.py
MSYS_NO_PATHCONV=1 docker exec evo-crm-community-evo-processor-1 python -m pytest tests/unit/services/adk/runners/test_standard_runner_price_gate.py -v
```

Expected: both tests in the file PASS.

- [ ] **Step 4: Commit**

```bash
git add src/services/adk/runners/standard_runner.py
git commit -m "feat: point price-gate release link at the new selection form"
```

---

## Task 3: Processor — restart the container so the live bot uses the new code

**Files:** none (deploy-only task)

- [ ] **Step 1: Restart and confirm healthy**

```bash
MSYS_NO_PATHCONV=1 docker restart evo-crm-community-evo-processor-1
```

Wait about 15 seconds, then:

```bash
docker logs --tail 50 evo-crm-community-evo-processor-1
```

Expected: no stack traces on boot, process listening (uvicorn/FastAPI startup log present).

- [ ] **Step 2: No commit** (nothing to commit — this step only restarts the already-committed container).

---

## Task 4: Rails — `GET /price_gate/release_form` renders the pending quote as a form

**Files:**
- Modify: `config/routes.rb:676` (add route after the existing `release_link` line)
- Modify: `app/controllers/api/v1/internal/price_gate_controller.rb` (add `release_form` public action + `release_form_html` and `format_brl` private helpers)
- Modify: `spec/requests/api/v1/internal/price_gate_spec.rb` (add `describe 'GET /api/v1/internal/price_gate/release_form'` block)

**Interfaces:**
- Consumes: `PriceGateService#pending_quote` (returns the `quote` hash stored by `#register_pending`, or `nil`/`{}` if none) — from Task 1's payload shape: `quote['produtos']` is an array of `{'nome', 'codigo', 'em_estoque', 'preco_venda', 'preco_custo'}` hashes with **string** keys (this is `JSON.parse` output, per `PriceGateService#state`).
- Produces: `release_form_html(produtos, phone, error: nil)` — private controller method, HTML string. Consumed by Task 5, which calls it again with `error:` set on validation failure, and by Task 5's `merge_submitted_products` (also defined in Task 5) which produces the `produtos`-shaped array this method expects when re-rendering after an error.

- [ ] **Step 1: Write the failing request specs**

Add to `spec/requests/api/v1/internal/price_gate_spec.rb`, right after the existing `describe 'POST /api/v1/internal/price_gate/release'` block (before the final `end` of the outer `RSpec.describe`):

```ruby
  describe 'GET /api/v1/internal/price_gate/release_form' do
    it 'rejects requests without the internal secret' do
      get '/api/v1/internal/price_gate/release_form', params: { phone: phone }

      expect(response).to have_http_status(:unauthorized)
    end

    it 'shows a "no pending quote" message when there is nothing pending' do
      get "/api/v1/internal/price_gate/release_form?internal_secret=#{secret}",
          params: { phone: phone }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Não há cotação pendente')
    end

    it 'renders the form with each product pre-filled from the pending quote' do
      post '/api/v1/internal/price_gate/check',
           params: {
             phone: phone, conversation_id: 'conv-1', agent_bot_id: 'bot-1',
             quote: {
               produtos: [
                 { nome: 'Alternador XPTO', codigo: '803097', em_estoque: true,
                   preco_venda: 450.0, preco_custo: 245.0 }
               ]
             }
           },
           headers: { 'X-Internal-Secret' => secret },
           as: :json

      get "/api/v1/internal/price_gate/release_form?internal_secret=#{secret}",
          params: { phone: phone }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Alternador XPTO')
      expect(response.body).to include('803097')
      expect(response.body).to include('value="450.00"')
      expect(response.body).to include('R$ 245,00')
    end
  end
```

- [ ] **Step 2: Run the specs to verify they fail**

```bash
MSYS_NO_PATHCONV=1 docker cp spec/requests/api/v1/internal/price_gate_spec.rb evo-crm-community-evo-crm-1:/app/spec/requests/api/v1/internal/price_gate_spec.rb
MSYS_NO_PATHCONV=1 docker exec evo-crm-community-evo-crm-1 bundle exec rspec spec/requests/api/v1/internal/price_gate_spec.rb
```

Expected: the 3 new examples FAIL with routing errors (`No route matches [GET] "/api/v1/internal/price_gate/release_form"`), the 5 pre-existing examples still PASS.

- [ ] **Step 3: Add the route**

In `config/routes.rb`, right after line 676 (`get 'api/v1/internal/price_gate/release_link', to: 'api/v1/internal/price_gate#release_from_link'`), add:

```ruby
  get 'api/v1/internal/price_gate/release_form', to: 'api/v1/internal/price_gate#release_form'
  post 'api/v1/internal/price_gate/release_form', to: 'api/v1/internal/price_gate#submit_release_form'
```

(Both routes are added together now since they target the same URL; Task 5 implements the `submit_release_form` action this POST route points to — until then, hitting it 404s/500s, which is fine, nothing links to it yet.)

- [ ] **Step 4: Implement `release_form` and its rendering helpers**

In `app/controllers/api/v1/internal/price_gate_controller.rb`, add this public action right after `release_from_link` (after the line `end` that closes it, before `private`):

```ruby
  # GET: shows the pending quote as an editable form (product selection,
  # price, discount). Deliberately has NO side effects - state only
  # changes on the POST below. A bare GET being safe to hit repeatedly
  # (e.g. from a link-preview bot) is a real fix over the old
  # release_from_link, which released the gate on GET.
  def release_form
    phone = params[:phone].presence
    return render_release_link_result(false, 'Telefone não informado no link.') if phone.blank?

    gate = PriceGateService.new(phone.delete('+'))
    quote = gate.pending_quote
    produtos = quote.is_a?(Hash) ? quote['produtos'] : nil

    if produtos.blank?
      return render_release_link_result(
        false,
        'Não há cotação pendente para esse cliente — já foi liberada antes ou expirou.'
      )
    end

    render html: release_form_html(produtos, phone).html_safe, layout: false
  end
```

Then add these private helpers, right after `render_release_link_result` (still above `trigger_resume`):

```ruby
  def format_brl(value)
    ActiveSupport::NumberHelper.number_to_currency(value, unit: 'R$ ', separator: ',', delimiter: '.')
  end

  def release_form_html(produtos, phone, error: nil)
    secret = ENV.fetch('INTERNAL_TOOLS_SECRET')
    rows = produtos.each_with_index.map do |produto, index|
      codigo = produto['codigo'].to_s
      nome = produto['nome'].to_s
      preco = produto['preco_venda']
      custo = produto['preco_custo']
      selected = produto.key?('selected') ? produto['selected'] : true
      preco_str = preco.is_a?(Numeric) ? format('%.2f', preco) : ''
      custo_html = custo.is_a?(Numeric) ? format_brl(custo) : '-'
      estoque_html = produto['em_estoque'] ? '✅ Em estoque' : '⚠️ Sem estoque'

      <<~ROW
        <div class="product-row" data-tabela="#{preco_str}">
          <label class="checkbox">
            <input type="checkbox" name="products[#{index}][selected]" value="1" #{selected ? 'checked' : ''}>
            <strong>#{ERB::Util.html_escape(nome)}</strong> (cód. #{ERB::Util.html_escape(codigo)})
          </label>
          <input type="hidden" name="products[#{index}][codigo]" value="#{ERB::Util.html_escape(codigo)}">
          <input type="hidden" name="products[#{index}][nome]" value="#{ERB::Util.html_escape(nome)}">
          <div class="row-fields">
            <label>Preço final (R$)
              <input type="number" step="0.01" min="0" class="preco-final" name="products[#{index}][preco_venda]" value="#{preco_str}">
            </label>
            <label>Desconto (%)
              <input type="number" step="0.01" class="desconto-percent" value="0">
            </label>
            <label>Desconto (R$)
              <input type="number" step="0.01" class="desconto-valor" value="0">
            </label>
            <span class="custo">Custo: #{custo_html}</span>
            <span class="estoque">#{estoque_html}</span>
          </div>
        </div>
      ROW
    end.join

    error_html = error ? "<p class=\"error\">⚠️ #{ERB::Util.html_escape(error)}</p>" : ''

    <<~HTML
      <!doctype html>
      <html lang="pt-BR">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Liberar preço</title>
          <style>
            body{font-family:-apple-system,system-ui,Segoe UI,Roboto,sans-serif;background:#0f172a;
              color:#e2e8f0;margin:0;padding:24px}
            .card{background:#1e293b;padding:24px;border-radius:16px;max-width:520px;margin:0 auto}
            h1{font-size:19px;margin:0 0 16px}
            .product-row{border-bottom:1px solid #334155;padding:12px 0}
            .checkbox{display:flex;align-items:center;gap:8px;margin-bottom:8px}
            .row-fields{display:flex;flex-wrap:wrap;gap:12px;align-items:center;font-size:13px;color:#94a3b8}
            .row-fields label{display:flex;flex-direction:column;gap:2px}
            input[type=number]{background:#0f172a;border:1px solid #334155;color:#e2e8f0;
              border-radius:6px;padding:6px;width:100px}
            .custo{color:#64748b}
            button{margin-top:16px;background:#22c55e;color:#0f172a;border:none;border-radius:8px;
              padding:10px 20px;font-weight:600;cursor:pointer}
            .error{color:#f59e0b}
          </style>
        </head>
        <body>
          <div class="card">
            <h1>Escolha o que enviar pro cliente</h1>
            #{error_html}
            <form method="post" action="?phone=#{ERB::Util.url_encode(phone)}&internal_secret=#{ERB::Util.url_encode(secret)}">
              #{rows}
              <button type="submit">Enviar pro cliente</button>
            </form>
          </div>
          <script>
            document.querySelectorAll('.product-row').forEach(function (row) {
              var tabela = parseFloat(row.dataset.tabela || '0');
              var finalInput = row.querySelector('.preco-final');
              var percentInput = row.querySelector('.desconto-percent');
              var valorInput = row.querySelector('.desconto-valor');

              function fromPercent() {
                var pct = parseFloat(percentInput.value || '0');
                var valor = tabela * pct / 100;
                valorInput.value = valor.toFixed(2);
                finalInput.value = (tabela - valor).toFixed(2);
              }
              function fromValor() {
                var valor = parseFloat(valorInput.value || '0');
                var pct = tabela ? (valor / tabela * 100) : 0;
                percentInput.value = pct.toFixed(2);
                finalInput.value = (tabela - valor).toFixed(2);
              }
              function fromFinal() {
                var fin = parseFloat(finalInput.value || '0');
                var valor = tabela - fin;
                var pct = tabela ? (valor / tabela * 100) : 0;
                percentInput.value = pct.toFixed(2);
                valorInput.value = valor.toFixed(2);
              }
              percentInput.addEventListener('input', fromPercent);
              valorInput.addEventListener('input', fromValor);
              finalInput.addEventListener('input', fromFinal);
            });
          </script>
        </body>
      </html>
    HTML
  end
```

- [ ] **Step 5: Redeploy and verify the specs pass**

```bash
MSYS_NO_PATHCONV=1 docker cp config/routes.rb evo-crm-community-evo-crm-1:/app/config/routes.rb
MSYS_NO_PATHCONV=1 docker cp app/controllers/api/v1/internal/price_gate_controller.rb evo-crm-community-evo-crm-1:/app/app/controllers/api/v1/internal/price_gate_controller.rb
MSYS_NO_PATHCONV=1 docker cp spec/requests/api/v1/internal/price_gate_spec.rb evo-crm-community-evo-crm-1:/app/spec/requests/api/v1/internal/price_gate_spec.rb
MSYS_NO_PATHCONV=1 docker exec evo-crm-community-evo-crm-1 bundle exec rspec spec/requests/api/v1/internal/price_gate_spec.rb
```

Expected: all 8 examples PASS (5 pre-existing + 3 new).

- [ ] **Step 6: Commit**

```bash
git add config/routes.rb app/controllers/api/v1/internal/price_gate_controller.rb spec/requests/api/v1/internal/price_gate_spec.rb
git commit -m "feat: add price-release selection form (GET)"
```

---

## Task 5: Rails — `POST /price_gate/release_form` sends the seller's chosen prices

**Files:**
- Modify: `app/controllers/api/v1/internal/price_gate_controller.rb` (add `submit_release_form` public action + `merge_submitted_products` and `build_price_message` private helpers)
- Modify: `spec/requests/api/v1/internal/price_gate_spec.rb` (add `describe 'POST /api/v1/internal/price_gate/release_form'` block)

**Interfaces:**
- Consumes: `release_form_html` and `format_brl` from Task 4 (same method signatures). `AgentBots::MessageCreator.new(agent_bot).create_bot_reply(content, conversation, force: true)` (existing service, `app/services/agent_bots/message_creator.rb` — takes a plain string `content`, an `AgentBot`, a `Conversation`, and `force:` to skip the bot's normal pending-only eligibility check).
- Produces: nothing further downstream — this is the last task that changes behavior; Task 6/7 only deploy and manually verify.

- [ ] **Step 1: Write the failing request specs**

Add to `spec/requests/api/v1/internal/price_gate_spec.rb`, after the `GET /api/v1/internal/price_gate/release_form` block added in Task 4:

```ruby
  describe 'POST /api/v1/internal/price_gate/release_form' do
    def register_quote
      post '/api/v1/internal/price_gate/check',
           params: {
             phone: phone, conversation_id: 'conv-1', agent_bot_id: 'bot-1',
             quote: {
               produtos: [
                 { nome: 'Alternador XPTO', codigo: '803097', em_estoque: true,
                   preco_venda: 450.0, preco_custo: 245.0 }
               ]
             }
           },
           headers: { 'X-Internal-Secret' => secret },
           as: :json
    end

    it 'rejects requests without the internal secret' do
      post '/api/v1/internal/price_gate/release_form', params: { phone: phone, products: {} }

      expect(response).to have_http_status(:unauthorized)
    end

    it 'shows a "no pending quote" message when there is nothing pending' do
      post "/api/v1/internal/price_gate/release_form?internal_secret=#{secret}",
           params: { phone: phone, products: {} }, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Não há cotação pendente')
    end

    it 'sends the chosen price to the customer and clears the gate' do
      allow(SellerEscalationExecution).to receive(:reset_for_conversation)
      register_quote

      conversation = instance_double(Conversation, id: 'conv-1')
      agent_bot = instance_double(AgentBot)
      allow(Conversation).to receive(:find_by).with(id: 'conv-1').and_return(conversation)
      allow(AgentBot).to receive(:find_by).with(id: 'bot-1').and_return(agent_bot)
      creator = instance_double(AgentBots::MessageCreator)
      allow(AgentBots::MessageCreator).to receive(:new).with(agent_bot).and_return(creator)
      expect(creator).to receive(:create_bot_reply).with(
        "Segue os valores:\n- Alternador XPTO (cód. 803097): R$ 450,00\n\nQualquer dúvida, fico à disposição!",
        conversation,
        force: true
      )

      post "/api/v1/internal/price_gate/release_form?internal_secret=#{secret}",
           params: { phone: phone, products: { '0' => { selected: '1', codigo: '803097', nome: 'Alternador XPTO', preco_venda: '450.00' } } },
           as: :json

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Mensagem enviada')
      expect(PriceGateService.new(phone).released?).to be(false)
      expect(PriceGateService.new(phone).pending_quote).to be_nil
    end

    it 'sends nothing and still clears the gate when no product is selected' do
      allow(SellerEscalationExecution).to receive(:reset_for_conversation)
      register_quote

      expect(AgentBots::MessageCreator).not_to receive(:new)

      post "/api/v1/internal/price_gate/release_form?internal_secret=#{secret}",
           params: { phone: phone, products: { '0' => { selected: '0', codigo: '803097', nome: 'Alternador XPTO', preco_venda: '450.00' } } },
           as: :json

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Nenhum produto selecionado')
      expect(PriceGateService.new(phone).pending_quote).to be_nil
    end

    it 're-renders the form with the error and keeps the quote pending when the price is invalid' do
      register_quote

      expect(AgentBots::MessageCreator).not_to receive(:new)

      post "/api/v1/internal/price_gate/release_form?internal_secret=#{secret}",
           params: { phone: phone, products: { '0' => { selected: '1', codigo: '803097', nome: 'Alternador XPTO', preco_venda: '' } } },
           as: :json

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Preço inválido')
      expect(response.body).to include('Alternador XPTO')
      expect(PriceGateService.new(phone).pending_quote).not_to be_nil
    end
  end
```

- [ ] **Step 2: Run the specs to verify they fail**

```bash
MSYS_NO_PATHCONV=1 docker cp spec/requests/api/v1/internal/price_gate_spec.rb evo-crm-community-evo-crm-1:/app/spec/requests/api/v1/internal/price_gate_spec.rb
MSYS_NO_PATHCONV=1 docker exec evo-crm-community-evo-crm-1 bundle exec rspec spec/requests/api/v1/internal/price_gate_spec.rb
```

Expected: the 5 new examples FAIL (`submit_release_form` action doesn't exist yet — `AbstractController::ActionNotFound` or similar), the 8 pre-existing examples still PASS.

- [ ] **Step 3: Implement `submit_release_form` and its helpers**

Add this public action in `app/controllers/api/v1/internal/price_gate_controller.rb`, right after `release_form`:

```ruby
  # POST: seller confirms which products/prices to send. Builds the final
  # message from exactly what was submitted and posts it straight to the
  # conversation - the bot/LLM never composes or sees this message, so
  # what the seller saw on the form is exactly what the customer gets.
  def submit_release_form
    phone = params[:phone].presence
    return render_release_link_result(false, 'Telefone não informado no link.') if phone.blank?

    gate = PriceGateService.new(phone.delete('+'))
    quote = gate.pending_quote
    produtos = quote.is_a?(Hash) ? quote['produtos'] : nil

    if produtos.blank?
      return render_release_link_result(
        false,
        'Não há cotação pendente para esse cliente — já foi liberada antes ou expirou.'
      )
    end

    products_params = params[:products].presence.try(:to_unsafe_h) || {}
    selected_params = products_params.values.select { |p| p['selected'] == '1' }

    error = nil
    items = selected_params.map do |p|
      price = p['preco_venda'].presence&.tr(',', '.')&.to_f
      error ||= "Preço inválido para #{p['nome']}." if price.nil? || price <= 0
      { nome: p['nome'], codigo: p['codigo'], preco: price }
    end

    if error
      merged = merge_submitted_products(produtos, products_params)
      return render html: release_form_html(merged, phone, error: error).html_safe, layout: false
    end

    conversation = Conversation.find_by(id: gate.pending_conversation_id)
    agent_bot = AgentBot.find_by(id: gate.pending_agent_bot_id)

    if items.any?
      unless conversation && agent_bot
        return render_release_link_result(
          false, 'Conversa ou bot não encontrado — a cotação pode ter expirado.'
        )
      end
      AgentBots::MessageCreator.new(agent_bot).create_bot_reply(
        build_price_message(items), conversation, force: true
      )
    end

    gate.release!
    SellerEscalationExecution.reset_for_conversation(gate.pending_conversation_id)
    gate.clear!

    render_release_link_result(
      true,
      items.any? ? 'Mensagem enviada ao cliente com os valores selecionados.' : 'Nenhum produto selecionado — nada foi enviado.'
    )
  end
```

Add these private helpers, next to `release_form_html`:

```ruby
  def build_price_message(items)
    lines = items.map { |i| "- #{i[:nome]} (cód. #{i[:codigo]}): #{format_brl(i[:preco])}" }
    "Segue os valores:\n#{lines.join("\n")}\n\nQualquer dúvida, fico à disposição!"
  end

  def merge_submitted_products(produtos, products_params)
    by_codigo = products_params.values.index_by { |p| p['codigo'] }
    produtos.map do |produto|
      submitted = by_codigo[produto['codigo']]
      next produto unless submitted

      produto.merge(
        'preco_venda' => submitted['preco_venda'].presence&.tr(',', '.')&.to_f || produto['preco_venda'],
        'selected' => submitted['selected'] == '1'
      )
    end
  end
```

- [ ] **Step 4: Redeploy and verify the specs pass**

```bash
MSYS_NO_PATHCONV=1 docker cp app/controllers/api/v1/internal/price_gate_controller.rb evo-crm-community-evo-crm-1:/app/app/controllers/api/v1/internal/price_gate_controller.rb
MSYS_NO_PATHCONV=1 docker cp spec/requests/api/v1/internal/price_gate_spec.rb evo-crm-community-evo-crm-1:/app/spec/requests/api/v1/internal/price_gate_spec.rb
MSYS_NO_PATHCONV=1 docker exec evo-crm-community-evo-crm-1 bundle exec rspec spec/requests/api/v1/internal/price_gate_spec.rb
```

Expected: all 13 examples PASS (8 pre-existing + 5 new).

- [ ] **Step 5: Commit**

```bash
git add app/controllers/api/v1/internal/price_gate_controller.rb spec/requests/api/v1/internal/price_gate_spec.rb
git commit -m "feat: send seller-chosen prices from the price-release form (POST)"
```

---

## Task 6: Rails — restart the container so the live app serves the new form

**Files:** none (deploy-only task)

- [ ] **Step 1: Restart and confirm healthy**

```bash
MSYS_NO_PATHCONV=1 docker restart evo-crm-community-evo-crm-1
```

Wait about 30 seconds (this container's boot is slower — Puma + asset checks), then:

```bash
docker logs --tail 50 evo-crm-community-evo-crm-1
```

Expected: no stack traces, Puma listening on port 3000. (An early `ruby: No such file or directory` line from a non-fatal helper-script fallback is normal and can be ignored — seen on every restart of this container historically.)

- [ ] **Step 2: No commit** (deploy-only step).

---

## Task 7: Manual end-to-end verification on real WhatsApp

**Files:** none (verification-only task, no code changes)

This mirrors how every prior price-gate feature in this project was signed off — synthetic/curl-based tests can't reliably exercise the real ADK session continuity, so the final gate is always a real WhatsApp conversation.

- [ ] **Step 1:** From a real WhatsApp number, ask about a product priced/stocked in Odoo in a way that triggers the price-gate guardrail (same phrasing style as prior incidents — asking directly for price/stock of a known part).
- [ ] **Step 2:** Confirm the private note appears in the EvoCRM conversation with a link now labeled "Escolher o que enviar pro cliente" (not the old "Liberar e enviar esse preço pro cliente").
- [ ] **Step 3:** Click the link. Confirm it opens the new form (dark theme, product row with checkbox, price/discount/cost fields) instead of an instant confirmation page.
- [ ] **Step 4:** Type a discount % into the "Desconto (%)" field for the product and confirm the "Preço final (R$)" field updates automatically (client-side JS sync).
- [ ] **Step 5:** Submit with the product checked. Confirm on WhatsApp the customer receives exactly one message listing the product and the final price you set — no mention of the original table price, no cost price, no stock quantity, no Odoo link.
- [ ] **Step 6:** Repeat the flow once more, this time unchecking the product before submitting. Confirm the customer receives no message, and the confirmation page says nothing was sent.
- [ ] **Step 7:** Report back what happened at each step (or exactly which one diverged from the above), so any follow-up fix can be scoped precisely.

---

## Self-Review

**Spec coverage:** every section of `docs/superpowers/specs/2026-08-04-release-price-form-design.md` maps to a task — architecture section 1 (quote enrichment) → Task 1; section 2 (note link) → Task 2; section 3 (GET form) → Task 4; section 4 (POST + message + validation + empty-selection + clear-on-submit) → Task 5; testing section → the request/unit specs embedded in Tasks 1, 2, 4, 5; manual WhatsApp testing → Task 7. Currency/discount UI requirements (% and R$, one drives the other) → Task 4's inline JS. Cost-price-never-to-customer constraint → enforced structurally (`build_price_message` in Task 5 never reads `preco_custo`).

**Placeholder scan:** none found — every step has literal file paths, complete code, and exact commands with expected output.

**Type consistency:** `release_form_html(produtos, phone, error: nil)` signature (Task 4) matches every call site in Task 5 (`release_form_html(merged, phone, error: error)`). `merge_submitted_products(produtos, products_params)` (Task 5) returns the same `produtos`-shaped array (string-keyed hashes with `'codigo'`/`'nome'`/`'preco_venda'`/`'preco_custo'`/`'em_estoque'`, plus an added `'selected'` key) that `release_form_html` already knows how to render. `AgentBots::MessageCreator#create_bot_reply(content, conversation, force:)` signature used in Task 5 matches the existing service at `app/services/agent_bots/message_creator.rb:6`.
