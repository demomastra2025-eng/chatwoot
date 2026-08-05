# frozen_string_literal: true

class Reminders::ConfirmationRequestService
  def initialize(reminder:, conversation:)
    @reminder = reminder
    @conversation = conversation
  end

  def perform
    return unless reminder.confirm_appointment_on_reply?

    validate_context!
    request = reminder.confirmation_request || create_request

    refresh_undelivered_request!(request)
    request
  end

  private

  attr_reader :reminder, :conversation

  def create_request
    Confirmations::CreateService.new(
      account: reminder.account,
      conversation: conversation,
      contact: conversation.contact,
      inbox: conversation.inbox,
      subject: appointment,
      reminder: reminder,
      title: 'Подтверждение записи',
      body: confirmation_body,
      expires_at: appointment.ends_at,
      metadata: confirmation_metadata,
      idempotency_key: "reminder:#{reminder.id}:confirm_appointment"
    ).perform
  end

  def appointment
    @appointment ||= reminder.remindable
  end

  def validate_context!
    raise ArgumentError, 'Appointment confirmation requires a persisted touch' unless reminder.persisted?
    raise ArgumentError, 'Appointment confirmation requires an appointment touch' unless appointment.is_a?(Scheduling::Appointment)

    validate_conversation_account!
    raise ArgumentError, 'Appointment confirmation requires an official WhatsApp Cloud inbox' unless whatsapp_cloud_conversation?
  end

  def validate_conversation_account!
    return if conversation.account_id == reminder.account_id

    raise ArgumentError, 'Appointment confirmation conversation must belong to the touch account'
  end

  def whatsapp_cloud_conversation?
    conversation.inbox.channel.is_a?(Channel::Whatsapp) && conversation.inbox.channel.provider == 'whatsapp_cloud'
  end

  def confirmation_body
    starts_at = appointment.starts_at&.in_time_zone(reminder.timezone)&.strftime('%Y-%m-%d %H:%M')
    [appointment.client_name, starts_at].compact_blank.join(' — ').presence || "Запись ##{appointment.id}"
  end

  def confirmation_metadata
    {
      'source' => 'automation_touch',
      'response_action' => reminder.response_action,
      'response_button_index' => reminder.response_button_index,
      'automation_rule_id' => reminder.metadata.to_h[Reminder::POST_DELIVERY_AUTOMATION_RULE_ID_KEY]
    }.compact
  end

  def refresh_undelivered_request!(request)
    return request if request.delivery_message_id.present? || !request.pending?

    request.update!(
      conversation: conversation,
      contact: conversation.contact,
      inbox: conversation.inbox,
      subject: appointment,
      reminder: reminder,
      body: confirmation_body,
      expires_at: appointment.ends_at,
      metadata: confirmation_metadata
    )
  end
end
