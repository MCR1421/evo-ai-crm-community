# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

RSpec.describe BotRuntime::AudioTranscriptionService do
  let(:file_url) { 'https://cdn.example.com/audio/note.ogg' }
  let(:groq_endpoint) { 'https://api.groq.com/openai/v1/audio/transcriptions' }
  let(:tempfile) do
    file = Tempfile.new(['note', '.ogg'])
    file.binmode
    file.write('fake audio bytes')
    file.rewind
    file
  end

  before do
    ENV['GROQ_API_KEY'] = 'test-groq-key'
    allow(Down).to receive(:download).with(file_url).and_return(tempfile)
  end

  after { tempfile.close! }

  describe '#call' do
    it 'returns the transcript text on a successful Groq response' do
      stub_request(:post, groq_endpoint)
        .with(headers: { 'Authorization' => 'Bearer test-groq-key' })
        .to_return(
          status: 200,
          body: { text: 'quanto custa o alternador do gol g5' }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      result = described_class.new(file_url, 'audio/ogg').call

      expect(result).to eq('quanto custa o alternador do gol g5')
    end

    it 'raises TranscriptionError when the download fails' do
      allow(Down).to receive(:download).with(file_url).and_raise(Down::Error, 'timeout')

      expect { described_class.new(file_url, 'audio/ogg').call }
        .to raise_error(BotRuntime::AudioTranscriptionService::TranscriptionError, /download failed/)
    end

    it 'raises TranscriptionError when Groq responds with a non-2xx status' do
      stub_request(:post, groq_endpoint).to_return(status: 500, body: 'internal error')

      expect { described_class.new(file_url, 'audio/ogg').call }
        .to raise_error(BotRuntime::AudioTranscriptionService::TranscriptionError, /Groq responded 500/)
    end

    it 'raises TranscriptionError when Groq returns an empty transcript' do
      stub_request(:post, groq_endpoint)
        .to_return(status: 200, body: { text: '' }.to_json, headers: { 'Content-Type' => 'application/json' })

      expect { described_class.new(file_url, 'audio/ogg').call }
        .to raise_error(BotRuntime::AudioTranscriptionService::TranscriptionError, /empty transcript/)
    end
  end
end
