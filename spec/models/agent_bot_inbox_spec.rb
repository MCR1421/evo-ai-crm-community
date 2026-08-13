# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AgentBotInbox do
  describe '#set_default_configurations' do
    it 'defaults status to active when status is not set' do
      agent_bot_inbox = described_class.new

      agent_bot_inbox.send(:set_default_configurations)

      expect(agent_bot_inbox.status).to eq('active')
    end

    it 'does not override an explicit status' do
      agent_bot_inbox = described_class.new(status: :inactive)

      agent_bot_inbox.send(:set_default_configurations)

      expect(agent_bot_inbox.status).to eq('inactive')
    end
  end

  describe '#should_process_conversation?' do
    let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
    let(:inbox) { Inbox.create!(name: 'Test Inbox', channel: channel) }
    let(:contact) { Contact.create!(name: 'Contact', email: "c-#{SecureRandom.hex(4)}@test.com") }
    let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
    let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
    let(:agent_bot) { AgentBot.create!(name: 'vascaino_core', outgoing_url: 'https://bot.example.com/webhook') }
    let(:agent_bot_inbox) { AgentBotInbox.create!(inbox: inbox, agent_bot: agent_bot) }

    it 'allows a pending conversation with no statuses configured (default behavior)' do
      conversation.update!(status: :pending)

      expect(agent_bot_inbox.should_process_conversation?(conversation)).to eq(true)
    end

    it 'allows an open conversation with no statuses configured as long as no human has replied yet' do
      conversation.update!(status: :open)

      expect(agent_bot_inbox.should_process_conversation?(conversation)).to eq(true)
    end

    it 'blocks an open conversation once a human agent has sent an outgoing message' do
      conversation.update!(status: :open)
      user = User.create!(name: 'Junior', email: "junior-#{SecureRandom.hex(4)}@test.com")
      Message.create!(inbox: inbox, conversation: conversation, message_type: :outgoing, sender: user, content: 'já te ajudo')

      expect(agent_bot_inbox.should_process_conversation?(conversation)).to eq(false)
    end

    it 'still allows an open conversation when only the bot itself has replied' do
      conversation.update!(status: :open)
      Message.create!(inbox: inbox, conversation: conversation, message_type: :outgoing, sender: agent_bot, content: 'oi')

      expect(agent_bot_inbox.should_process_conversation?(conversation)).to eq(true)
    end

    it 'blocks a resolved conversation with no statuses configured' do
      conversation.update!(status: :resolved)

      expect(agent_bot_inbox.should_process_conversation?(conversation)).to eq(false)
    end
  end
end
