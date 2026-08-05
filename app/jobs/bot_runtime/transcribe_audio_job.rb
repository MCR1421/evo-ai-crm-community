# frozen_string_literal: true

module BotRuntime
  class TranscribeAudioJob < ApplicationJob
    queue_as :bot_runtime

    FALLBACK_TEXT = 'Não consegui entender o áudio, você pode escrever a mensagem?'

    def perform(event, attachment, agent_bot, conversation)
      transcript = AudioTranscriptionService.new(attachment).call

      event[:message_content] = transcript
      SendEventJob.perform_later(event)

      Rails.logger.info "[AudioTranscription] transcribed for conversation=#{conversation.display_id}"
    rescue AudioTranscriptionService::TranscriptionError => e
      Rails.logger.error "[AudioTranscription] failed for conversation=#{conversation.display_id}: #{e.message}"
      AgentBots::MessageCreator.new(agent_bot).create_bot_reply(FALLBACK_TEXT, conversation, force: true)
    end
  end
end
