# Página de liberação de preço com seleção de produto/desconto

Data: 2026-08-04
Status: aprovado, aguardando implementação

## Contexto

O price gate hoje bloqueia o bot de vazar preço/estoque sem liberação humana
(ver memória `evocrm_vascaino_core_agent.md`). O fluxo atual, já em produção e
confirmado funcionando via WhatsApp real:

1. Bot tenta responder com preço/estoque sem ter chamado
   `checar_liberacao_preco` com sucesso nesse turno.
2. Guardrail (`standard_runner.py`) bloqueia, registra uma cotação pendente
   no Redis (`price_gate:<phone>`, via `PriceGateService`) e posta uma nota
   privada na conversa com os dados do produto (código, preço de venda,
   preço de custo, estoque, link Odoo) e um link de liberação de 1 clique.
3. Clicar no link (`GET /price_gate/release_link`) libera o gate e reativa o
   bot, que manda pro cliente só um "tem/não tem em estoque" — nunca preço
   nem quantidade exata.

Esse desenho deliberadamente nunca manda preço automaticamente. Este spec
substitui esse link de 1-clique por uma página onde o vendedor escolhe,
produto a produto, o que e por quanto mandar.

## Objetivo

Ao clicar no link da nota privada, o vendedor cai numa página com todos os
produtos da cotação pendente, e pode:
- Marcar quais produtos quer mandar pro cliente (não precisa ser todos).
- Ver e editar o preço de venda de cada um (pré-preenchido com o preço de
  tabela do Odoo).
- Aplicar desconto por produto, em % ou em R$ (os dois campos, um alimenta o
  outro).
- Ver o preço de custo ao lado, só como referência de margem (não editável,
  não vai pro cliente).
- Confirmar o envio — nesse momento a mensagem é montada e postada na
  conversa.

## Arquitetura

Sem novo serviço. Tudo dentro do `evo-ai-crm-community` (Rails) +
`evo-ai-processor-community` (Python), reaproveitando o `PriceGateService`
(Redis) que já existe.

### 1. Guardrail (`standard_runner.py`) — quote mais rico

`_register_pending_price_gate` já busca `list_price`/`standard_price`/
`qty_available` no Odoo via `_fetch_odoo_product_details` (usado hoje só pra
montar a nota privada). O payload enviado a `POST /price_gate/check` passa a
incluir esses valores em cada item de `quote.produtos`:

```json
{
  "produtos": [
    {
      "nome": "Alternador XPTO",
      "codigo": "803097",
      "em_estoque": true,
      "preco_venda": 450.00,
      "preco_custo": 245.00
    }
  ]
}
```

Preço de custo nunca é lido pelo LLM em nenhum ponto do fluxo — só entra
nesse JSON armazenado no Redis, que só a página Rails lê depois.

### 2. Nota privada — novo destino do link

O link na nota privada passa a apontar para
`GET /price_gate/release_form?phone=...&internal_secret=...` em vez de
`/price_gate/release_link`. Mesma autenticação por query param (sem login),
mesmo padrão já usado hoje.

O endpoint antigo (`/release_link`, `PriceGateController#release_from_link`)
fica no código sem uso — não é mais linkado por nada, não precisa ser
removido agora.

### 3. `GET /price_gate/release_form` — mostra o formulário

Sem efeito colateral (correção em relação ao endpoint antigo, que era um GET
com efeito colateral — risco de ser disparado sem querer por bots de preview
de link no WhatsApp/navegador).

- Lê a cotação pendente do Redis pra aquele telefone.
- Se não existir (expirada/já usada): renderiza aviso "Cotação não
  encontrada — já foi liberada antes ou expirou", sem formulário.
- Se existir: renderiza um `<form method="post">` com uma linha por produto
  — checkbox, preço de venda (input numérico, pré-preenchido), % desconto,
  R$ desconto (calculam um o outro via JS simples, sem framework), preço de
  custo (texto, só leitura).

### 4. `POST /price_gate/release_form` — confirma e envia

- Valida: cada produto marcado precisa ter preço de venda numérico > 0. Erro
  de validação reexibe o formulário com os valores já digitados preservados
  (não perde o que o vendedor já preencheu) e uma mensagem de erro.
- Monta a mensagem final (só com os produtos marcados):

  ```
  Segue os valores:
  - Alternador XPTO (cód. 803097): R$ 450,00
  - Motor de partida ABC (cód. 803112): R$ 620,00

  Qualquer dúvida, fico à disposição!
  ```

  Se desconto foi aplicado, mostra só o preço final — não expõe "de/por"
  nem o percentual.
- Posta essa mensagem direto na conversa via
  `Message.create!(message_type: :outgoing, private: false, ...)` —
  **não** aciona o bot/IA pra essa etapa. A mensagem que o cliente recebe é
  exatamente a que o vendedor viu confirmada na tela.
- Se nenhum produto foi marcado: não posta nada na conversa.
- Em caso de sucesso (postou ou decidiu não postar por seleção vazia):
  chama `gate.release!`, dispara `SellerEscalationExecution.reset_for_conversation`
  (mesmo que o fluxo antigo já fazia) e `gate.clear!` — cotação inteira é
  descartada, incluindo produtos não marcados (não ficam pendentes pra
  depois; se precisar mandar depois, o bot gera nova cotação a partir de uma
  nova busca do cliente).
- Se `Message.create!` falhar: mostra erro na página, gate **não** é
  liberado nem limpo (permite tentar de novo sem perder a cotação).
- Sucesso renderiza a mesma página de confirmação estilizada (dark theme)
  já usada hoje, adaptada pro texto certo.

## Fora de escopo

- Não há mudança no `checar_liberacao_preco` nem na instrução do agente —
  o comportamento do bot em relação a preço (nunca informar, sempre
  escalar) continua o mesmo; essa página é só a ferramenta do vendedor.
- Não remove o endpoint antigo `/release_link`, só para de ser referenciado.
- Não adiciona login/autenticação de usuário — mesma autenticação por
  secret token da nota privada.

## Testes

- Unit `PriceGateController#release_form` GET: renderiza produtos certos a
  partir de um quote fake no Redis; renderiza aviso quando não há quote.
- Unit `#release_form` POST: caso feliz (produtos selecionados → mensagem
  postada com texto certo, `private: false`, gate limpo); caso vazio (nada
  selecionado → nada postado, gate limpo do mesmo jeito); caso preço
  inválido (reexibe formulário com erro, gate intacto).
- Integração: reproduzir o cenário real ponta a ponta — guardrail bloqueia →
  nota privada com link novo → GET mostra formulário com preço/custo
  corretos → POST manda mensagem → conferir via Postgres que a mensagem
  outgoing foi criada com o texto esperado.
- Manual real no WhatsApp antes de considerar fechado (mesmo padrão das
  features anteriores desta mesma área).
