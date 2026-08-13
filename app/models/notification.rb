# == Schema Information
#
# Table name: notifications
#
#  id                   :uuid             not null, primary key
#  last_activity_at     :datetime
#  meta                 :jsonb
#  notification_type    :integer          not null
#  primary_actor_type   :string           not null
#  read_at              :datetime
#  secondary_actor_type :string
#  snoozed_until        :datetime
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  primary_actor_id     :uuid             not null
#  secondary_actor_id   :uuid
#  user_id              :uuid             not null
#
# Indexes
#
#  index_notifications_on_user_id                  (user_id)
#  uniq_primary_actor_per_account_notifications    (primary_actor_type,primary_actor_id)
#  uniq_secondary_actor_per_account_notifications  (secondary_actor_type,secondary_actor_id)
#
class Notification < ApplicationRecord
  include MessageFormatHelper
  belongs_to :user

  belongs_to :primary_actor, polymorphic: true
  belongs_to :secondary_actor, polymorphic: true, optional: true

  NOTIFICATION_TYPES = {
    conversation_creation: 1,
    conversation_assignment: 2,
    assigned_conversation_new_message: 3,
    conversation_mention: 4,
    participating_conversation_new_message: 5,
    pipeline_task_assigned: 20,
    pipeline_task_due_soon: 21,
    pipeline_task_overdue: 22,
    pipeline_task_completed: 23
  }.freeze

  enum notification_type: NOTIFICATION_TYPES

  before_create :set_last_activity_at
  after_create_commit :process_notification_delivery, :dispatch_create_event
  after_destroy_commit :dispatch_destroy_event
  after_update_commit :dispatch_update_event

  PRIMARY_ACTORS = ['Conversation'].freeze

  def push_event_data
    # Secondary actor could be nil for cases like system assigning conversation
    payload = {
      id: id,
      notification_type: notification_type,
      primary_actor_type: primary_actor_type,
      primary_actor_id: primary_actor_id,
      read_at: read_at,
      secondary_actor: secondary_actor&.push_event_data,
      user: user&.push_event_data,
      created_at: created_at.to_i,
      last_activity_at: last_activity_at.to_i,
      snoozed_until: snoozed_until,
      meta: meta
    }
    payload.merge!(primary_actor_data) if primary_actor.present?
    payload
  end

  def fcm_push_data
    {
      id: id,
      notification_type: notification_type,
      primary_actor_id: primary_actor_id,
      primary_actor_type: primary_actor_type,
      primary_actor: primary_actor.push_event_data.with_indifferent_access.slice('conversation_id', 'id', 'display_id')
    }
  end

  # rubocop:disable Metrics/MethodLength
  def push_message_title
    # WhatsApp-style: title is the contact's name (matches the OS-level
    # notification convention every messaging app uses — sender as title,
    # message text as body), falling back to a description for notification
    # types that aren't tied to a specific message from a specific person.
    case notification_type
    when 'conversation_creation', 'sla_missed_first_response'
      return '' unless conversation&.respond_to?(:messages)
      sender_name(conversation.messages.first)
    when 'assigned_conversation_new_message', 'participating_conversation_new_message', 'conversation_mention'
      sender_name(secondary_actor)
    when 'conversation_assignment'
      return '' unless conversation&.respond_to?(:display_id)
      I18n.t('notifications.notification_title.conversation_assignment', display_id: conversation.display_id)
    else
      return '' unless primary_actor&.respond_to?(:display_id)
      I18n.t('notifications.notification_title.conversation_creation', display_id: primary_actor.display_id,
                                                                         inbox_name: primary_actor.try(:inbox)&.name)
    end
  end
  # rubocop:enable Metrics/MethodLength

  def push_message_body
    case notification_type
    when 'conversation_creation', 'sla_missed_first_response'
      return '' unless conversation&.respond_to?(:messages)
      message_content(conversation.messages.first)
    when 'assigned_conversation_new_message', 'participating_conversation_new_message', 'conversation_mention'
      message_content(secondary_actor)
    when 'conversation_assignment'
      return '' unless conversation&.respond_to?(:messages)
      message_content((conversation.messages.incoming.last || conversation.messages.outgoing.last))
    else
      ''
    end
  end

  # WhatsApp-style push image: the message's own photo when it's a photo
  # message (matches WhatsApp showing the sent picture, not the sender's
  # profile photo), falling back to the contact's avatar otherwise, and
  # to blank when there's no message/sender to attribute it to.
  def push_message_image_url
    actor = case notification_type
            when 'conversation_creation', 'sla_missed_first_response'
              conversation&.messages&.first
            when 'assigned_conversation_new_message', 'participating_conversation_new_message', 'conversation_mention'
              secondary_actor
            when 'conversation_assignment'
              conversation&.messages&.incoming&.last || conversation&.messages&.outgoing&.last
            end

    image_attachment = actor.try(:attachments)&.detect { |a| a.file_type == 'image' }
    url = if image_attachment
            image_attachment.thumb_url.presence || image_attachment.file_url
          else
            sender = actor.try(:sender)
            sender.respond_to?(:avatar_url) ? sender.avatar_url : ''
          end
    return '' if url.blank?

    # FCM fetches this image server-side from Google's own infrastructure,
    # not from the recipient's device — a LAN-only BACKEND_URL (default_url_options)
    # is unreachable from there, so swap in a publicly routable host just for this field.
    public_base = ENV.fetch('PUSH_IMAGE_BASE_URL', '')
    return url if public_base.blank?

    url.sub(ENV.fetch('BACKEND_URL', ''), public_base)
  rescue StandardError
    ''
  end

  def conversation
    primary_actor
  end

  private

  def sender_name(actor)
    actor.try(:sender)&.name || ''
  end

  def message_content(actor)
    content = actor.try(:content)
    attachments = actor.try(:attachments)

    if content.present?
      transform_user_mention_content(content.truncate_words(10))
    else
      attachments.present? ? I18n.t('notifications.attachment') : I18n.t('notifications.no_content')
    end
  end

  def process_notification_delivery
    push_subscribed = user_subscribed_to_notification?('push')
    email_subscribed = user_subscribed_to_notification?('email')

    Rails.logger.info("📱 [NOTIFICATION] Processing delivery for notification #{id}, type: #{notification_type}, user: #{user&.email}, push_subscribed: #{push_subscribed}, email_subscribed: #{email_subscribed}")

    if push_subscribed
      Rails.logger.info("📱 [NOTIFICATION] Enqueuing push notification job for notification #{id}")
      Notification::PushNotificationJob.perform_later(self)
    else
      Rails.logger.info("📱 [NOTIFICATION] Skipping push notification job - user not subscribed to push for #{notification_type}")
    end

    # Should we do something about the case where user subscribed to both push and email ?
    # In future, we could probably add condition here to enqueue the job for 30 seconds later
    # when push enabled and then check in email job whether notification has been read already.
    Notification::EmailNotificationJob.perform_later(self) if email_subscribed

    Notification::RemoveDuplicateNotificationJob.perform_later(self)
  end

  def user_subscribed_to_notification?(delivery_type)
    notification_setting = user.notification_settings.first
    return false if notification_setting.blank?

    # Check if the user has subscribed to the specified type of notification
    notification_setting.public_send("#{delivery_type}_#{notification_type}?")
  end

  def dispatch_create_event
    Rails.configuration.dispatcher.dispatch(NOTIFICATION_CREATED, Time.zone.now, notification: self)
  end

  def dispatch_update_event
    Rails.configuration.dispatcher.dispatch(NOTIFICATION_UPDATED, Time.zone.now, notification: self)
  end

  def dispatch_destroy_event
    Rails.configuration.dispatcher.dispatch(NOTIFICATION_DELETED, Time.zone.now, notification: self)
  end

  def set_last_activity_at
    self.last_activity_at = created_at
  end

  def primary_actor_data
    {
      primary_actor: primary_actor&.push_event_data,
      # TODO: Rename push_message_title to push_message_body
      push_message_title: push_message_body,
      push_message_body: push_message_body
    }
  end
end
