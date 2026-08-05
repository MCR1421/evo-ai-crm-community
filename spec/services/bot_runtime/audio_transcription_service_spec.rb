# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

RSpec.describe BotRuntime::AudioTranscriptionService do
  let(:groq_endpoint) { 'https://api.groq.com/openai/v1/audio/transcriptions' }
  let(:file) { double('ActiveStorage::Attached::One', content_type: 'audio/ogg') } # rubocop:disable RSpec/VerifiedDoubles
  let(:attachment) { instance_double(Attachment, file: file) }

  before do
    ENV['GROQ_API_KEY'] = 'test-groq-key'
    allow(file).to receive(:download) do |&block|
      block.call('fake audio bytes')
    end
  end

  describe '#call' do
    it 'returns the transcript text on a successful Groq response' do
      stub_request(:post, groq_endpoint)
        .with(headers: { 'Authorization' => 'Bearer test-groq-key' })
        .to_return(
          status: 200,
          body: { text: 'quanto custa o alternador do gol g5' }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      result = described_class.new(attachment).call

      expect(result).to eq('quanto custa o alternador do gol g5')
    end

    it 'raises TranscriptionError when the download fails' do
      allow(file).to receive(:download).and_raise(ActiveStorage::FileNotFoundError, 'not found')

      expect { described_class.new(attachment).call }
        .to raise_error(BotRuntime::AudioTranscriptionService::TranscriptionError, /download failed/)
    end

    it 'raises TranscriptionError when Groq responds with a non-2xx status' do
      stub_request(:post, groq_endpoint).to_return(status: 500, body: 'internal error')

      expect { described_class.new(attachment).call }
        .to raise_error(BotRuntime::AudioTranscriptionService::TranscriptionError, /Groq responded 500/)
    end

    it 'raises TranscriptionError when Groq returns an empty transcript' do
      stub_request(:post, groq_endpoint)
        .to_return(status: 200, body: { text: '' }.to_json, headers: { 'Content-Type' => 'application/json' })

      expect { described_class.new(attachment).call }
        .to raise_error(BotRuntime::AudioTranscriptionService::TranscriptionError, /empty transcript/)
    end
  end
end
