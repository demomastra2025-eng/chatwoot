# == Schema Information
#
# Table name: notifications
#
#  id                   :bigint           not null, primary key
#  last_activity_at     :datetime
#  meta                 :jsonb
#  notification_type    :integer          not null
#  primary_actor_type   :string           not null
#  read_at              :datetime
#  secondary_actor_type :string
#  snoozed_until        :datetime
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  account_id           :bigint           not null
#  primary_actor_id     :bigint           not null
#  secondary_actor_id   :bigint
#  user_id              :bigint           not null
#
# Indexes
#
#  idx_notifications_performance                   (user_id,account_id,snoozed_until,read_at)
#  index_notifications_on_account_id               (account_id)
#  index_notifications_on_last_activity_at         (last_activity_at)
#  index_notifications_on_user_id                  (user_id)
#  uniq_primary_actor_per_account_notifications    (primary_actor_type,primary_actor_id)
#  uniq_secondary_actor_per_account_notifications  (secondary_actor_type,secondary_actor_id)
#

class Notification < ApplicationRecord
  include MessageFormatHelper
  belongs_to :account
  belongs_to :user

  belongs_to :primary_actor, polymorphic: true
  belongs_to :secondary_actor, polymorphic: true, optional: true

  NOTIFICATION_TYPES = {
    conversation_creation: 1,
    conversation_assignment: 2,
    assigned_conversation_new_message: 3,
    conversation_mention: 4,
    participating_conversation_new_message: 5,
    sla_missed_first_response: 6,
    sla_missed_next_response: 7,
    sla_missed_resolution: 8,
    captain_notification: 9
  }.freeze

  enum notification_type: NOTIFICATION_TYPES

  before_validation :capture_render_snapshot, on: :create
  before_create :set_last_activity_at
  after_create_commit :process_notification_delivery, :dispatch_create_event
  after_destroy_commit :dispatch_destroy_event
  after_update_commit :dispatch_update_event

  PRIMARY_ACTORS = ['Conversation'].freeze
  RENDER_SNAPSHOT_KEY = 'render_snapshot'.freeze

  def push_event_data
    {
      id: id,
      notification_type: notification_type,
      primary_actor_type: primary_actor_type,
      primary_actor_id: primary_actor_id,
      read_at: read_at,
      secondary_actor: secondary_actor_payload,
      user: user&.push_event_data,
      created_at: created_at.to_i,
      last_activity_at: last_activity_at.to_i,
      snoozed_until: snoozed_until,
      meta: meta,
      account_id: account_id
    }
      .merge(primary_actor_data)
  end

  def fcm_push_data
    {
      id: id,
      notification_type: notification_type,
      primary_actor_id: primary_actor_id,
      primary_actor_type: primary_actor_type,
      primary_actor: primary_actor_payload.with_indifferent_access.slice('conversation_id', 'id')
    }
  end

  def push_message_title
    snapshot_value('push_message_title').presence || build_live_push_message_title
  end

  def push_message_body
    snapshot_value('push_message_body').presence || build_live_push_message_body
  end

  def conversation
    primary_actor
  end

  def conversation_display_id
    snapshot_value('conversation', 'display_id') || live_conversation&.display_id || primary_actor_display_id
  end

  def primary_actor_payload
    primary_actor&.push_event_data || snapshot_value('primary_actor') || default_primary_actor_payload
  end

  def secondary_actor_payload
    secondary_actor&.push_event_data || snapshot_value('secondary_actor')
  end

  private

  def message_body(actor)
    return I18n.t('notifications.no_content') if actor.blank?

    sender_name = sender_name(actor)
    content = message_content(actor)
    sender_name.present? ? "#{sender_name}: #{content}" : content
  end

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
    Notification::PushNotificationJob.perform_later(self) if user_subscribed_to_notification?('push')
    Notification::TelegramNotificationJob.perform_later(self) if user_subscribed_to_notification?('telegram')

    # Should we do something about the case where user subscribed to both push and email ?
    # In future, we could probably add condition here to enqueue the job for 30 seconds later
    # when push enabled and then check in email job whether notification has been read already.
    Notification::EmailNotificationJob.perform_later(self) if user_subscribed_to_notification?('email')

    Notification::RemoveDuplicateNotificationJob.perform_later(self)
  end

  def user_subscribed_to_notification?(delivery_type)
    notification_setting = user.notification_settings.find_by(account_id: account.id)
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
    # Pass serialized data instead of ActiveRecord object to avoid DeserializationError
    # when the async EventDispatcherJob runs after the notification has been deleted
    Rails.configuration.dispatcher.dispatch(
      NOTIFICATION_DELETED,
      Time.zone.now,
      notification_data: {
        id: id,
        user_id: user_id,
        account_id: account_id
      }
    )
  end

  def set_last_activity_at
    self.last_activity_at = created_at
  end

  def primary_actor_data
    {
      primary_actor: primary_actor_payload,
      # TODO: Rename push_message_title to push_message_body
      push_message_title: push_message_title,
      push_message_body: push_message_body
    }
  end

  def build_live_push_message_title
    i18n_key = notification_title_i18n_key
    return '' unless i18n_key

    if notification_type == 'conversation_creation'
      I18n.t(i18n_key, display_id: live_conversation_display_id, inbox_name: live_conversation_inbox_name)
    elsif notification_type == 'captain_notification'
      captain_notification_title
    elsif conversation_scoped_notification?
      I18n.t(i18n_key, display_id: live_conversation_display_id)
    else
      I18n.t(i18n_key, display_id: primary_actor_display_id)
    end
  end

  def build_live_push_message_body
    case notification_type
    when 'conversation_creation', 'sla_missed_first_response'
      message_body(live_conversation&.messages&.first)
    when 'assigned_conversation_new_message', 'participating_conversation_new_message', 'conversation_mention'
      message_body(secondary_actor)
    when 'conversation_assignment', 'sla_missed_next_response', 'sla_missed_resolution'
      latest_message = live_conversation&.messages&.incoming&.last || live_conversation&.messages&.outgoing&.last
      message_body(latest_message)
    when 'captain_notification'
      captain_notification_message
    else
      ''
    end
  end

  def build_render_snapshot
    {
      'push_message_title' => build_live_push_message_title,
      'push_message_body' => build_live_push_message_body,
      'primary_actor' => build_primary_actor_snapshot,
      'secondary_actor' => secondary_actor&.push_event_data,
      'conversation' => build_conversation_snapshot
    }.compact
  end

  def build_primary_actor_snapshot
    primary_actor&.push_event_data || default_primary_actor_payload
  end

  def build_conversation_snapshot
    {
      display_id: live_conversation_display_id,
      inbox_name: live_conversation_inbox_name,
      account_id: account_id
    }.compact
  end

  def capture_render_snapshot
    snapshot = build_render_snapshot
    return if snapshot.blank?

    snapshot_meta = (meta || {}).deep_stringify_keys
    snapshot_meta[RENDER_SNAPSHOT_KEY] ||= snapshot
    self.meta = snapshot_meta
  end

  def conversation_scoped_notification?
    %w[conversation_assignment assigned_conversation_new_message participating_conversation_new_message
       conversation_mention captain_notification].include?(notification_type)
  end

  def default_primary_actor_payload
    {
      id: primary_actor_display_id,
      meta: {}
    }.compact.with_indifferent_access
  end

  def live_conversation
    primary_actor if primary_actor.is_a?(Conversation)
  end

  def live_conversation_display_id
    live_conversation&.display_id || primary_actor_display_id
  end

  def live_conversation_inbox_name
    live_conversation&.inbox&.name.to_s
  end

  def notification_title_i18n_key
    {
      'conversation_creation' => 'notifications.notification_title.conversation_creation',
      'conversation_assignment' => 'notifications.notification_title.conversation_assignment',
      'assigned_conversation_new_message' => 'notifications.notification_title.assigned_conversation_new_message',
      'participating_conversation_new_message' => 'notifications.notification_title.assigned_conversation_new_message',
      'conversation_mention' => 'notifications.notification_title.conversation_mention',
      'sla_missed_first_response' => 'notifications.notification_title.sla_missed_first_response',
      'sla_missed_next_response' => 'notifications.notification_title.sla_missed_next_response',
      'sla_missed_resolution' => 'notifications.notification_title.sla_missed_resolution',
      'captain_notification' => 'notifications.notification_title.captain_notification'
    }[notification_type]
  end

  def primary_actor_display_id
    primary_actor&.try(:display_id) || primary_actor_id
  end

  def captain_notification_title
    captain_notification_meta[:title].presence || I18n.t(
      'notifications.notification_title.captain_notification',
      display_id: live_conversation_display_id
    )
  end

  def captain_notification_message
    captain_notification_meta[:message].presence || ''
  end

  def captain_notification_meta
    raw_meta = meta.is_a?(Hash) ? meta['captain_notification'] || meta[:captain_notification] : nil
    raw_meta.is_a?(Hash) ? raw_meta.with_indifferent_access : {}
  end

  def render_snapshot
    raw_snapshot = meta.is_a?(Hash) ? meta[RENDER_SNAPSHOT_KEY] || meta[RENDER_SNAPSHOT_KEY.to_sym] : nil
    return {} if raw_snapshot.blank?

    raw_snapshot.with_indifferent_access
  end

  def snapshot_value(*keys)
    value = render_snapshot.dig(*keys)
    value.is_a?(Hash) ? value.with_indifferent_access : value
  end
end
