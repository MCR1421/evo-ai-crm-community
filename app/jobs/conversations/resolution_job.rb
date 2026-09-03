class Conversations::ResolutionJob < ApplicationJob
  queue_as :low

  def perform(account: nil)
    auto_resolve_after = GlobalConfigService.load('AUTO_RESOLVE_DURATION', nil)&.to_i
    return if auto_resolve_after.nil? || auto_resolve_after.zero?

    auto_resolve_message = GlobalConfigService.load('AUTO_RESOLVE_MESSAGE', nil)
    auto_resolve_label = GlobalConfigService.load('AUTO_RESOLVE_LABEL', nil)
    auto_resolve_ignore_waiting = GlobalConfigService.load('AUTO_RESOLVE_IGNORE_WAITING', false)

    # limiting the number of conversations to be resolved to avoid any performance issues
    resolvable_conversations = conversation_scope(auto_resolve_after, auto_resolve_ignore_waiting).limit(Limits::BULK_ACTIONS_LIMIT)
    resolvable_conversations.each do |conversation|
      # send message from bot that conversation has been resolved
      ::MessageTemplates::Template::AutoResolve.new(conversation: conversation).perform if auto_resolve_message.present?
      conversation.add_labels(auto_resolve_label) if auto_resolve_label.present?
      conversation.update!(status: :resolved)
    end
  end

  private

  def conversation_scope(auto_resolve_after, ignore_waiting)
    if ignore_waiting
      Conversation.resolvable_not_waiting(auto_resolve_after)
    else
      Conversation.resolvable_all(auto_resolve_after)
    end
  end
end
