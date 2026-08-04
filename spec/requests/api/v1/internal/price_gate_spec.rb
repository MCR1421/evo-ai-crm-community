require 'rails_helper'

RSpec.describe 'Api::V1::Internal::PriceGate', type: :request do
  let(:phone) { '5522999990000' }
  let(:secret) { 'test-secret' }

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with('INTERNAL_TOOLS_SECRET').and_return(secret)
  end

  after { Redis::Alfred.delete("price_gate:#{phone}") }

  describe 'POST /api/v1/internal/price_gate/check' do
    it 'rejects requests without the internal secret' do
      post '/api/v1/internal/price_gate/check', params: { phone: phone }, as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'registers the pending quote and returns released: false on first call' do
      post '/api/v1/internal/price_gate/check',
           params: { phone: phone, conversation_id: 'conv-1', agent_bot_id: 'bot-1', quote: { produto: 'Alternador Bosch' } },
           headers: { 'X-Internal-Secret' => secret },
           as: :json

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['released']).to be(false)
    end
  end

  describe 'POST /api/v1/internal/price_gate/release' do
    it 'returns released: true and clears escalation state' do
      allow(SellerEscalationExecution).to receive(:reset_for_conversation)

      post '/api/v1/internal/price_gate/check',
           params: { phone: phone, conversation_id: 'conv-1', agent_bot_id: 'bot-1', quote: { produto: 'Alternador Bosch' } },
           headers: { 'X-Internal-Secret' => secret },
           as: :json

      allow_any_instance_of(Api::V1::Internal::PriceGateController).to receive(:trigger_resume)

      post '/api/v1/internal/price_gate/release',
           params: { phone: phone },
           headers: { 'X-Internal-Secret' => secret },
           as: :json

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['released']).to be(true)
    end

    it 'accepts the secret as a query param and extracts phone from meta.sender.phone_number (Automation Rule webhook shape)' do
      allow(SellerEscalationExecution).to receive(:reset_for_conversation)

      post '/api/v1/internal/price_gate/check',
           params: { phone: phone, conversation_id: 'conv-1', agent_bot_id: 'bot-1', quote: { produto: 'Alternador Bosch' } },
           headers: { 'X-Internal-Secret' => secret },
           as: :json

      allow_any_instance_of(Api::V1::Internal::PriceGateController).to receive(:trigger_resume)

      post "/api/v1/internal/price_gate/release?internal_secret=#{secret}",
           params: { id: 'conv-1', meta: { sender: { phone_number: "+#{phone}" } } },
           as: :json

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['released']).to be(true)
    end

    it 'rejects release without a valid secret via header or query param' do
      post '/api/v1/internal/price_gate/release', params: { phone: phone }, as: :json

      expect(response).to have_http_status(:unauthorized)
    end
  end

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

    it 'has no side effects - the pending quote survives the GET' do
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
      expect(PriceGateService.new(phone).pending_quote).not_to be_nil
    end
  end

  describe 'POST /api/v1/internal/price_gate/release_form' do
    def register_quote
      post '/api/v1/internal/price_gate/check',
           params: {
             phone: phone, conversation_id: 'conv-1', agent_bot_id: 'bot-1',
             quote: {
               produtos: [
                 { nome: 'Alternador XPTO', codigo: '803097', em_estoque: true,
                   preco_venda: 450.0, preco_custo: 245.0,
                   marca: 'BOSCH', voltagem: '12V', amperagem: nil, medidas: [],
                   shop_link: 'https://pr-distribuidora1.odoo.com/shop/product/22768' }
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
        "🔧 803097\nAlternador XPTO\n💰 Preço: R$ 450,00 📦\nEstoque: Em estoque\n" \
        "🏭 Marca: BOSCH\n🔌 Voltagem: 12V\n" \
        "🛒 Ver no site (fotos e aplicação): https://pr-distribuidora1.odoo.com/shop/product/22768" \
        "\n\nQualquer dúvida, fico à disposição!",
        conversation,
        force: true
      )

      post "/api/v1/internal/price_gate/release_form?internal_secret=#{secret}",
           params: { phone: phone, products: { '0' => { modo: 'com_preco', codigo: '803097', nome: 'Alternador XPTO', preco_venda: '450.00' } } },
           as: :json

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Mensagem enviada')
      expect(PriceGateService.new(phone).released?).to be(false)
      expect(PriceGateService.new(phone).pending_quote).to be_nil
    end

    it 'sends a stock-only message (no price, no cost, no exact quantity) when the seller picks "sem preço"' do
      allow(SellerEscalationExecution).to receive(:reset_for_conversation)
      register_quote

      conversation = instance_double(Conversation, id: 'conv-1')
      agent_bot = instance_double(AgentBot)
      allow(Conversation).to receive(:find_by).with(id: 'conv-1').and_return(conversation)
      allow(AgentBot).to receive(:find_by).with(id: 'bot-1').and_return(agent_bot)
      creator = instance_double(AgentBots::MessageCreator)
      allow(AgentBots::MessageCreator).to receive(:new).with(agent_bot).and_return(creator)
      expect(creator).to receive(:create_bot_reply).with(
        "🔧 803097\nAlternador XPTO\nEstoque: Em estoque\n" \
        "🏭 Marca: BOSCH\n🔌 Voltagem: 12V\n" \
        "🛒 Ver no site (fotos e aplicação): https://pr-distribuidora1.odoo.com/shop/product/22768" \
        "\n\nQualquer dúvida, fico à disposição!",
        conversation,
        force: true
      )

      post "/api/v1/internal/price_gate/release_form?internal_secret=#{secret}",
           params: { phone: phone, products: { '0' => { modo: 'sem_preco', codigo: '803097', nome: 'Alternador XPTO', preco_venda: '450.00' } } },
           as: :json

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Mensagem enviada')
      expect(response.body).not_to include('450')
      expect(response.body).not_to include('245')
      expect(PriceGateService.new(phone).pending_quote).to be_nil
    end

    it 'includes Amperagem and Medidas when present, and never includes cost price' do
      allow(SellerEscalationExecution).to receive(:reset_for_conversation)
      post '/api/v1/internal/price_gate/check',
           params: {
             phone: phone, conversation_id: 'conv-1', agent_bot_id: 'bot-1',
             quote: {
               produtos: [
                 { nome: '602100  EST. FORD CARGO, CORCEL, SANTANA 65A 14V WAPSA', codigo: '602100',
                   em_estoque: true, preco_venda: 85.0, preco_custo: 42.0,
                   marca: 'WAPSA', voltagem: '12V', amperagem: '65A',
                   medidas: [['Diâmetro Externo', '127mm'], ['Pacote', '24,5mm']],
                   shop_link: 'https://pr-distribuidora1.odoo.com/shop/product/16273' }
               ]
             }
           },
           headers: { 'X-Internal-Secret' => secret },
           as: :json

      conversation = instance_double(Conversation, id: 'conv-1')
      agent_bot = instance_double(AgentBot)
      allow(Conversation).to receive(:find_by).with(id: 'conv-1').and_return(conversation)
      allow(AgentBot).to receive(:find_by).with(id: 'bot-1').and_return(agent_bot)
      creator = instance_double(AgentBots::MessageCreator)
      allow(AgentBots::MessageCreator).to receive(:new).with(agent_bot).and_return(creator)
      expect(creator).to receive(:create_bot_reply).with(
        "🔧 602100\n602100  EST. FORD CARGO, CORCEL, SANTANA 65A 14V WAPSA\n" \
        "💰 Preço: R$ 85,00 📦\nEstoque: Em estoque\n🏭 Marca: WAPSA\n🔌 Voltagem: 12V\n" \
        "⚡ Amperagem: 65A\n📏 Medidas:\n   • Diâmetro Externo: 127mm\n   • Pacote: 24,5mm\n" \
        "🛒 Ver no site (fotos e aplicação): https://pr-distribuidora1.odoo.com/shop/product/16273" \
        "\n\nQualquer dúvida, fico à disposição!",
        conversation,
        force: true
      )

      post "/api/v1/internal/price_gate/release_form?internal_secret=#{secret}",
           params: { phone: phone, products: { '0' => { modo: 'com_preco', codigo: '602100', nome: '602100  EST. FORD CARGO, CORCEL, SANTANA 65A 14V WAPSA', preco_venda: '85.00' } } },
           as: :json

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Mensagem enviada')
    end

    it 'sends nothing and still clears the gate when no product is selected' do
      allow(SellerEscalationExecution).to receive(:reset_for_conversation)
      register_quote

      expect(AgentBots::MessageCreator).not_to receive(:new)

      post "/api/v1/internal/price_gate/release_form?internal_secret=#{secret}",
           params: { phone: phone, products: { '0' => { modo: 'nao', codigo: '803097', nome: 'Alternador XPTO', preco_venda: '450.00' } } },
           as: :json

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Nenhum produto selecionado')
      expect(PriceGateService.new(phone).pending_quote).to be_nil
    end

    it 're-renders the form with the error and keeps the quote pending when the price is invalid' do
      register_quote

      expect(AgentBots::MessageCreator).not_to receive(:new)

      post "/api/v1/internal/price_gate/release_form?internal_secret=#{secret}",
           params: { phone: phone, products: { '0' => { modo: 'com_preco', codigo: '803097', nome: 'Alternador XPTO', preco_venda: '' } } },
           as: :json

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Preço inválido')
      expect(response.body).to include('Alternador XPTO')
      expect(PriceGateService.new(phone).pending_quote).not_to be_nil
    end

    it 'rejects a price with a numeric prefix followed by garbage' do
      register_quote

      expect(AgentBots::MessageCreator).not_to receive(:new)

      post "/api/v1/internal/price_gate/release_form?internal_secret=#{secret}",
           params: { phone: phone, products: { '0' => { modo: 'com_preco', codigo: '803097', nome: 'Alternador XPTO', preco_venda: '12abc' } } },
           as: :json

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Preço inválido')
      expect(PriceGateService.new(phone).pending_quote).not_to be_nil
    end

    it 'accepts a pt-BR grouped-decimal price and sends the correct (uncorrupted) value to the customer' do
      allow(SellerEscalationExecution).to receive(:reset_for_conversation)
      register_quote

      conversation = instance_double(Conversation, id: 'conv-1')
      agent_bot = instance_double(AgentBot)
      allow(Conversation).to receive(:find_by).with(id: 'conv-1').and_return(conversation)
      allow(AgentBot).to receive(:find_by).with(id: 'bot-1').and_return(agent_bot)
      creator = instance_double(AgentBots::MessageCreator)
      allow(AgentBots::MessageCreator).to receive(:new).with(agent_bot).and_return(creator)
      expect(creator).to receive(:create_bot_reply).with(
        "🔧 803097\nAlternador XPTO\n💰 Preço: R$ 1.234,56 📦\nEstoque: Em estoque\n" \
        "🏭 Marca: BOSCH\n🔌 Voltagem: 12V\n" \
        "🛒 Ver no site (fotos e aplicação): https://pr-distribuidora1.odoo.com/shop/product/22768" \
        "\n\nQualquer dúvida, fico à disposição!",
        conversation,
        force: true
      )

      post "/api/v1/internal/price_gate/release_form?internal_secret=#{secret}",
           params: { phone: phone, products: { '0' => { modo: 'com_preco', codigo: '803097', nome: 'Alternador XPTO', preco_venda: '1.234,56' } } },
           as: :json

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Mensagem enviada')
    end
  end
end
