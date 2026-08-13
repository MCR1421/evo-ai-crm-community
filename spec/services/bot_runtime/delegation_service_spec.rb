# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BotRuntime::DelegationService do
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
  let(:inbox) { Inbox.create!(name: 'Test Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Contact', email: "c-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let(:agent_bot) { AgentBot.create!(name: 'vascaino_core', outgoing_url: 'https://bot.example.com/webhook') }

  describe '#delegate' do
    context 'when the message has no audio attachment' do
      let(:message) do
        Message.create!(inbox: inbox, conversation: conversation, message_type: :incoming, content: 'oi, tem alternador?')
      end

      it 'enqueues SendEventJob directly' do
        expect(BotRuntime::SendEventJob).to receive(:perform_later) do |event|
          expect(event[:message_content]).to eq('oi, tem alternador?')
        end
        expect(BotRuntime::TranscribeAudioJob).not_to receive(:perform_later)

        described_class.new(agent_bot, message, conversation).delegate
      end
    end

    context 'when the message has an audio attachment' do
      let(:message) do
        Message.create!(inbox: inbox, conversation: conversation, message_type: :incoming, content: '')
      end

      before do
        blob = ActiveStorage::Blob.create_and_upload!(
          io: StringIO.new('fake audio bytes'),
          filename: 'note.ogg',
          content_type: 'audio/ogg'
        )
        attachment = message.attachments.build(file_type: 'audio')
        attachment.file.attach(blob)
        message.save!
      end

      it 'enqueues TranscribeAudioJob instead of SendEventJob' do
        expect(BotRuntime::SendEventJob).not_to receive(:perform_later)
        expect(BotRuntime::TranscribeAudioJob).to receive(:perform_later) do |event, attachment, bot, conv|
          expect(event[:conversation_id]).to eq(conversation.display_id)
          expect(attachment).to eq(message.attachments.first)
          expect(attachment.file.content_type).to eq('audio/ogg')
          expect(bot).to eq(agent_bot)
          expect(conv).to eq(conversation)
        end

        described_class.new(agent_bot, message, conversation).delegate
      end
    end

    context 'when the message has an image attachment' do
      let(:message) do
        Message.create!(inbox: inbox, conversation: conversation, message_type: :incoming, content: '')
      end

      before do
        blob = ActiveStorage::Blob.create_and_upload!(
          io: StringIO.new('fake image bytes'),
          filename: 'peca.jpg',
          content_type: 'image/jpeg'
        )
        attachment = message.attachments.build(file_type: 'image')
        attachment.file.attach(blob)
        message.save!
      end

      it 'sends the fallback reply directly and never delegates to the bot' do
        expect(BotRuntime::SendEventJob).not_to receive(:perform_later)
        expect(BotRuntime::TranscribeAudioJob).not_to receive(:perform_later)
        expect_any_instance_of(AgentBots::MessageCreator)
          .to receive(:create_bot_reply)
          .with(BotRuntime::DelegationService::IMAGE_FALLBACK_TEXT, conversation, force: true)

        described_class.new(agent_bot, message, conversation).delegate
      end
    end
  end
end
