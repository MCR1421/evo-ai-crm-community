module AutoAssignmentHandler
  extend ActiveSupport::Concern
  include Events::Types

  included do
    after_save :run_auto_assignment
  end

  private

  def run_auto_assignment
    # Round robin kicks in on conversation create (any status, so bot-owned
    # inboxes get an assignee without touching status/pending) and whenever
    # status changes to open
    return unless newly_created? || conversation_status_changed_to_open?
    return unless should_run_auto_assignment?

    ::AutoAssignment::AgentAssignmentService.new(conversation: self, allowed_agent_ids: inbox.member_ids_with_assignment_capacity).perform
  end

  def newly_created?
    previous_changes.key?(:id)
  end

  def should_run_auto_assignment?
    return false unless inbox.enable_auto_assignment?

    # run only if assignee is blank or doesn't have access to inbox
    assignee.blank? || inbox.members.exclude?(assignee)
  end
end
