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
        "Segue as informações:\n- Alternador XPTO (cód. 803097): R$ 450,00\n\nQualquer dúvida, fico à disposição!",
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

    it 'sends a stock-only message (no price) when the seller picks "sem preço"' do
      allow(SellerEscalationExecution).to receive(:reset_for_conversation)
      register_quote

      conversation = instance_double(Conversation, id: 'conv-1')
      agent_bot = instance_double(AgentBot)
      allow(Conversation).to receive(:find_by).with(id: 'conv-1').and_return(conversation)
      allow(AgentBot).to receive(:find_by).with(id: 'bot-1').and_return(agent_bot)
      creator = instance_double(AgentBots::MessageCreator)
      allow(AgentBots::MessageCreator).to receive(:new).with(agent_bot).and_return(creator)
      expect(creator).to receive(:create_bot_reply).with(
        "Segue as informações:\n- Alternador XPTO (cód. 803097): temos em estoque, vendedor vai te passar o valor\n\nQualquer dúvida, fico à disposição!",
        conversation,
        force: true
      )

      post "/api/v1/internal/price_gate/release_form?internal_secret=#{secret}",
           params: { phone: phone, products: { '0' => { modo: 'sem_preco', codigo: '803097', nome: 'Alternador XPTO', em_estoque: '1', preco_venda: '450.00' } } },
           as: :json

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Mensagem enviada')
      expect(PriceGateService.new(phone).pending_quote).to be_nil
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
        "Segue as informações:\n- Alternador XPTO (cód. 803097): R$ 1.234,56\n\nQualquer dúvida, fico à disposição!",
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
