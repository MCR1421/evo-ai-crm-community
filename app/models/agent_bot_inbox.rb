# == Schema Information
#
# Table name: agent_bot_inboxes
#
#  id                               :uuid             not null, primary key
#  allowed_conversation_statuses    :jsonb            not null
#  allowed_label_ids                :jsonb            not null
#  auto_approve_responses           :boolean          default(FALSE), not null
#  auto_reject_explicit_words       :boolean          default(FALSE), not null
#  auto_reject_offensive_sentiment  :boolean          default(FALSE), not null
#  explicit_words_filter            :jsonb            not null
#  facebook_allowed_post_ids        :jsonb            not null
#  facebook_comment_replies_enabled :boolean          default(FALSE), not null
#  facebook_interaction_type        :string           default("both"), not null
#  ignored_label_ids                :jsonb            not null
#  moderation_enabled               :boolean          default(FALSE), not null
#  sentiment_analysis_enabled       :boolean          default(FALSE), not null
#  status                           :integer          default("active")
#  created_at                       :datetime         not null
#  updated_at                       :datetime         not null
#  agent_bot_id                     :uuid
#  facebook_comment_agent_bot_id    :uuid
#  inbox_id                         :uuid
#
# Indexes
#
#  index_agent_bot_inboxes_on_allowed_conversation_statuses    (allowed_conversation_statuses) USING gin
#  index_agent_bot_inboxes_on_allowed_label_ids                (allowed_label_ids) USING gin
#  index_agent_bot_inboxes_on_auto_reject_explicit_words       (auto_reject_explicit_words)
#  index_agent_bot_inboxes_on_auto_reject_offensive_sentiment  (auto_reject_offensive_sentiment)
#  index_agent_bot_inboxes_on_explicit_words_filter            (explicit_words_filter) USING gin
#  index_agent_bot_inboxes_on_facebook_allowed_post_ids        (facebook_allowed_post_ids) USING gin
#  index_agent_bot_inboxes_on_facebook_comment_agent_bot_id    (facebook_comment_agent_bot_id)
#  index_agent_bot_inboxes_on_facebook_interaction_type        (facebook_interaction_type)
#  index_agent_bot_inboxes_on_ignored_label_ids                (ignored_label_ids) USING gin
#  index_agent_bot_inboxes_on_moderation_enabled               (moderation_enabled)
#
# Foreign Keys
#
#  fk_rails_...  (facebook_comment_agent_bot_id => agent_bots.id) ON DELETE => nullify
#
class AgentBotInbox < ApplicationRecord
  validates :inbox_id, presence: true
  validates :agent_bot_id, presence: true
  validate :validate_allowed_conversation_statuses
  validate :validate_allowed_label_ids
  validate :validate_ignored_label_ids
  validate :validate_facebook_interaction_type
  before_validation :set_default_configurations

  belongs_to :inbox
  belongs_to :agent_bot
  belongs_to :facebook_comment_agent_bot, class_name: 'AgentBot', optional: true, foreign_key: 'facebook_comment_agent_bot_id'
  enum status: { active: 0, inactive: 1 }

  # Valid conversation statuses
  VALID_CONVERSATION_STATUSES = %w[open resolved pending snoozed].freeze

  # Valid Facebook interaction types
  VALID_FACEBOOK_INTERACTION_TYPES = %w[comments_only messages_only both].freeze

  # Check if conversation status is allowed
  # Default to 'pending' if no statuses are configured
  def allows_conversation_status?(status)
    status_str = status.to_s
    Rails.logger.info "[AgentBotInbox] allows_conversation_status? - status: #{status.inspect} (#{status.class}), status_str: #{status_str}, allowed_statuses: #{allowed_conversation_statuses.inspect}"

    # If no statuses configured, default to pending only
    if allowed_conversation_statuses.blank?
      result = status_str == 'pending'
      Rails.logger.info "[AgentBotInbox] No statuses configured, defaulting to pending check: #{result}"
      return result
    end

    result = allowed_conversation_statuses.include?(status_str)
    Rails.logger.info "[AgentBotInbox] Status check result: #{result} (looking for #{status_str} in #{allowed_conversation_statuses.inspect})"
    result
  end

  # Check if conversation has any allowed label
  # If no labels are configured, allow all conversations (labels check is bypassed)
  # If labels are configured, conversation OR its contact must have at least one of them
  def allows_conversation_labels?(conversation)
    return true if allowed_label_ids.blank?

    allowed_ids_str = allowed_label_ids.map(&:to_s)
    resolved_label_ids = resolve_label_ids_for_conversation(conversation)

    (allowed_ids_str & resolved_label_ids).any?
  end

  # Check if conversation has any ignored label
  # If conversation has any ignored label, it should not be processed
  # Checks both conversation labels and contact labels
  #
  # NOTE: Same ID resolution as allows_conversation_labels? — we resolve
  # tag names to CRM Label IDs since they are different ID spaces.
  def has_ignored_labels?(conversation)
    return false if ignored_label_ids.blank?

    ignored_ids_str = ignored_label_ids.map(&:to_s)
    resolved_label_ids = resolve_label_ids_for_conversation(conversation)

    (ignored_ids_str & resolved_label_ids).any?
  end

  # Check if conversation matches all conditions
  def should_process_conversation?(conversation)
    # First check if conversation has ignored labels - if so, don't process
    if has_ignored_labels?(conversation)
      return false
    end

    status_allowed = allows_conversation_status?(conversation.status) || open_without_human_reply?(conversation)
    labels_allowed = allows_conversation_labels?(conversation)

    return false unless status_allowed
    return false unless labels_allowed

    true
  end

  # After a handoff (e.g. transfer_to_human) flips a conversation to 'open', the bot would
  # otherwise go silent even on a trivial customer follow-up ("quero 5 unidades") until a
  # human replies. Let it keep helping while status is 'open' as long as no human agent has
  # actually sent a message yet - the moment one does, this returns false and the bot stays quiet.
  def open_without_human_reply?(conversation)
    conversation.status.to_s == 'open' && !conversation.messages.outgoing.exists?(sender_type: 'User')
  end

  # Get the appropriate agent bot for a conversation
  # For Facebook post conversations, check if comment replies are enabled
  # and if a specific agent bot is configured for comments
  def agent_bot_for_conversation(conversation)
    return agent_bot unless conversation.post_conversation?
    return nil unless facebook_comment_replies_enabled?

    # Use specific comment agent bot if configured, otherwise use main agent bot
    facebook_comment_agent_bot || agent_bot
  end

  # Check if Facebook comment replies are enabled
  def facebook_comment_replies_enabled?
    facebook_comment_replies_enabled == true
  end

  # Check if bot should process Facebook comments
  def should_process_facebook_comments?
    return false unless inbox&.facebook?
    return false if facebook_interaction_type == 'messages_only'
    true
  end

  # Check if bot should process Facebook direct messages
  def should_process_facebook_messages?
    return false unless inbox&.facebook?
    return false if facebook_interaction_type == 'comments_only'
    true
  end

  # Check if a specific post is allowed (if facebook_allowed_post_ids is empty, all posts are allowed)
  def post_allowed?(post_id)
    return true if facebook_allowed_post_ids.blank?
    facebook_allowed_post_ids.map(&:to_s).include?(post_id.to_s)
  end

  # Moderation helper methods
  def moderation_enabled?
    moderation_enabled == true
  end

  def should_check_explicit_words?
    moderation_enabled? && explicit_words_filter.present?
  end

  def should_check_sentiment?
    moderation_enabled? && sentiment_analysis_enabled == true
  end

  def requires_response_approval?
    moderation_enabled? && auto_approve_responses == false
  end

  def should_auto_reject_explicit_words?
    moderation_enabled? && auto_reject_explicit_words == true
  end

  def should_auto_reject_offensive_sentiment?
    moderation_enabled? && auto_reject_offensive_sentiment == true
  end

  private

  UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  # Resolve all label names from a conversation (and its contact) to CRM Label UUIDs.
  #
  # The CRM has two label systems:
  #   1. `labels` table — CRM Labels with UUID primary keys, scoped by account
  #   2. `tags` table (acts_as_taggable_on) — used by Conversation/Contact via label_list
  #
  # Tag names may be either:
  #   - A CRM Label UUID (conversations store the Label UUID as the tag name)
  #   - A human-readable title like "test-ia" (contacts store the label title as the tag name)
  #
  # This method collects tag names from both conversation and contact, then resolves
  # them to CRM Label UUIDs for comparison against allowed_label_ids / ignored_label_ids.
  def resolve_label_ids_for_conversation(conversation)
    resolved = []

    # --- Conversation tag names ---
    conversation_tag_names = conversation.label_list || []
    resolved.concat(resolve_tag_names_to_label_ids(conversation_tag_names))

    # --- Contact tag names ---
    if conversation.contact.present?
      contact_tag_names = conversation.contact.label_list || []
      resolved.concat(resolve_tag_names_to_label_ids(contact_tag_names))
    end

    resolved.uniq
  end

  # Convert an array of tag names to CRM Label UUIDs.
  # Tag names that look like UUIDs are treated as CRM Label IDs directly.
  # Other names are resolved by looking up Label records by title.
  def resolve_tag_names_to_label_ids(tag_names)
    return [] if tag_names.blank?

    label_ids = []
    title_names = []

    tag_names.each do |name|
      if name.match?(UUID_PATTERN)
        label_ids << name
      else
        title_names << name
      end
    end

    if title_names.any?
      ids_from_titles = Label.where(title: title_names).pluck(:id).map(&:to_s)
      label_ids.concat(ids_from_titles)
    end

    label_ids
  end

  def set_default_configurations
    self.status ||= :active
    self.allowed_conversation_statuses ||= []
    self.allowed_label_ids ||= []
    self.ignored_label_ids ||= []
    self.facebook_interaction_type ||= 'both'
    self.facebook_allowed_post_ids ||= []
    self.explicit_words_filter ||= []
  end

  def validate_allowed_conversation_statuses
    return if allowed_conversation_statuses.blank?

    invalid_statuses = allowed_conversation_statuses - VALID_CONVERSATION_STATUSES
    return if invalid_statuses.empty?

    errors.add(:allowed_conversation_statuses, "contains invalid statuses: #{invalid_statuses.join(', ')}")
  end

  def validate_allowed_label_ids
    return if allowed_label_ids.blank?

    existing_label_ids = Label.pluck(:id).map(&:to_s)
    invalid_label_ids = allowed_label_ids.map(&:to_s) - existing_label_ids
    return if invalid_label_ids.empty?

    errors.add(:allowed_label_ids, "contains invalid label IDs: #{invalid_label_ids.join(', ')}")
  end

  def validate_ignored_label_ids
    return if ignored_label_ids.blank?

    existing_label_ids = Label.pluck(:id).map(&:to_s)
    invalid_label_ids = ignored_label_ids.map(&:to_s) - existing_label_ids
    return if invalid_label_ids.empty?

    errors.add(:ignored_label_ids, "contains invalid label IDs: #{invalid_label_ids.join(', ')}")
  end

  def validate_facebook_interaction_type
    return unless facebook_interaction_type.present?

    unless VALID_FACEBOOK_INTERACTION_TYPES.include?(facebook_interaction_type)
      errors.add(:facebook_interaction_type, "must be one of: #{VALID_FACEBOOK_INTERACTION_TYPES.join(', ')}")
    end
  end
end
