# frozen_string_literal: true

class Captain::FollowUpDeliveryConfirmation
  MINIMUM_STEP_GAP = 1.hour

  def self.acknowledged?(message)
    return false unless message.outgoing? && !message.private? && !message.failed?
    return true if message.source_id.present? || message.delivered? || message.read?

    local_delivery?(message)
  end

  def self.local_delivery?(message)
    return true if message.inbox.channel_type == 'Channel::WebWidget'

    message.inbox.channel_type == 'Channel::Api' && message.inbox.channel.additional_attributes.to_h['provider'].blank?
  end

  def initialize(message:)
    @message = message
  end

  def perform
    message.with_lock do
      message.reload
      marker = follow_up_marker
      next false if marker.blank?
      next cancel_after_provider_failure!(marker) if message.failed?
      next false if marker['delivery_failed_at'].present?
      next false unless provider_acknowledged?
      next false if marker['next_step_scheduled'] == true

      context = delivery_context(marker)
      next false if context.blank?

      schedule_next_step!(context)
      mark_delivery_confirmed!(marker)
      true
    end
  end

  private

  attr_reader :message

  def provider_acknowledged?
    self.class.acknowledged?(message)
  end

  def marker_key
    message.additional_attributes.to_h['captain_follow_up'].present? ? 'captain_follow_up' : 'captain_follow_up_origin'
  end

  def follow_up_marker
    message.additional_attributes.to_h[marker_key].to_h.deep_stringify_keys
  end

  def cancel_after_provider_failure!(marker)
    assistant_id = marker['assistant_id']
    anchor_message_id = marker['anchor_message_id']
    next_step_index = marker['step_index'].to_i + 1
    return false if assistant_id.blank? || anchor_message_id.blank?

    idempotency_keys = [anchor_message_id, message.id].uniq.map do |next_anchor_id|
      "captain_follow_up:#{assistant_id}:#{next_anchor_id}:#{next_step_index}"
    end
    reminders = message.account.reminders.where(idempotency_key: idempotency_keys)
    found_reminder = reminders.exists?
    reminders.find_each { |reminder| reminder.cancel!('Previous follow-up failed at the provider') }
    mark_delivery_failed!(marker)
    found_reminder
  end

  def delivery_context(marker)
    assistant = Captain::Assistant.find_by(id: marker['assistant_id'], account_id: message.account_id)
    conversation = message.conversation
    anchor_message = conversation.messages.find_by(id: marker['anchor_message_id'])
    step_index = marker['step_index'].to_i
    settings = assistant&.config.to_h.deep_stringify_keys.fetch('follow_up_settings', {}).to_h
    steps = Array(settings['steps']).first(Captain::Conversation::FollowUpJob::MAX_STEPS).map do |step|
      step.to_h.deep_stringify_keys
    end

    return if assistant.blank? || anchor_message.blank?
    return unless settings['enabled'] == true
    return unless assistant.inboxes.exists?(id: conversation.inbox_id)

    {
      assistant: assistant,
      conversation: conversation,
      anchor_message: anchor_message,
      step_index: step_index,
      settings: settings,
      next_step: steps[step_index + 1]
    }
  end

  def schedule_next_step!(context)
    next_step = context[:next_step]
    return if next_step.blank?

    delay_seconds = next_step['delay_seconds'].to_i
    return unless delay_seconds.positive?

    settings = context[:settings]
    anchor_message = settings['timing_mode'] == 'absolute_from_last_incoming' ? context[:anchor_message] : message
    scheduled_at = scheduled_at_for(context, delay_seconds)

    Captain::Conversation::FollowUpJob.schedule!(
      conversation: context[:conversation],
      assistant: context[:assistant],
      anchor_message: anchor_message,
      step_index: context[:step_index] + 1,
      delay_seconds: delay_seconds,
      scheduled_at: scheduled_at
    )
  end

  def scheduled_at_for(context, delay_seconds)
    return unless context[:settings]['timing_mode'] == 'absolute_from_last_incoming'

    conversation = context[:conversation]
    root_anchor = context[:anchor_message]
    schedule_base_at = conversation.messages.incoming
                                   .where('created_at <= ?', root_anchor.created_at)
                                   .reorder(created_at: :desc)
                                   .pick(:created_at) || root_anchor.created_at
    earliest_send_at = context[:step_index].negative? ? Time.current : message.created_at + MINIMUM_STEP_GAP
    [schedule_base_at + delay_seconds.seconds, earliest_send_at].max
  end

  def mark_delivery_confirmed!(marker)
    attributes = message.additional_attributes.to_h.deep_dup
    attributes[marker_key] = marker.merge(
      'delivery_confirmed_at' => Time.current.iso8601,
      'next_step_scheduled' => true
    )
    message.update_columns(additional_attributes: attributes, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
  end

  def mark_delivery_failed!(marker)
    attributes = message.additional_attributes.to_h.deep_dup
    attributes[marker_key] = marker.merge('delivery_failed_at' => Time.current.iso8601)
    message.update_columns(additional_attributes: attributes, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
  end
end
