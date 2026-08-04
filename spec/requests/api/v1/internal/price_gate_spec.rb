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
  end
end
