# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BotRuntime::TranscribeAudioJob do
  let(:agent_bot) { instance_double(AgentBot) }
  let(:conversation) { instance_double(Conversation, display_id: 4) }
  let(:event) { { conversation_id: 4, agent_bot_id: 'bot-1', message_content: '' } }
  let(:audio_file_url) { 'https://cdn.example.com/audio/note.ogg' }

  describe '#perform' do
    it 'sets message_content to the transcript and enqueues SendEventJob on success' do
      service_double = instance_double(BotRuntime::AudioTranscriptionService, call: 'quanto custa o alternador')
      allow(BotRuntime::AudioTranscriptionService).to receive(:new)
        .with(audio_file_url, 'audio/ogg').and_return(service_double)

      expect(BotRuntime::SendEventJob).to receive(:perform_later) do |sent_event|
        expect(sent_event[:message_content]).to eq('quanto custa o alternador')
        expect(sent_event[:conversation_id]).to eq(conversation.display_id)
      end

      described_class.new.perform(event, audio_file_url, 'audio/ogg', agent_bot, conversation)
    end

    it 'sends the deterministic fallback and does not enqueue SendEventJob when transcription fails' do
      service_double = instance_double(BotRuntime::AudioTranscriptionService)
      allow(BotRuntime::AudioTranscriptionService).to receive(:new)
        .with(audio_file_url, 'audio/ogg').and_return(service_double)
      allow(service_double).to receive(:call)
        .and_raise(BotRuntime::AudioTranscriptionService::TranscriptionError, 'Groq responded 500')

      expect(BotRuntime::SendEventJob).not_to receive(:perform_later)

      creator_double = instance_double(AgentBots::MessageCreator)
      allow(AgentBots::MessageCreator).to receive(:new).with(agent_bot).and_return(creator_double)
      expect(creator_double).to receive(:create_bot_reply)
        .with(described_class::FALLBACK_TEXT, conversation, force: true)

      described_class.new.perform(event, audio_file_url, 'audio/ogg', agent_bot, conversation)
    end
  end
end
