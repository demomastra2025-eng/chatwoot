class Integrations::Medelement::AiBookingOutcomeJob < ApplicationJob
  queue_as :medelement_provider_commands

  CUSTOMER_MESSAGE_ID_KEY = 'ai_booking_customer_message_id'.freeze
  STAFF_NOTE_ID_KEY = 'ai_booking_staff_note_id'.freeze

  class BindingNotReadyError < StandardError; end

  retry_on BindingNotReadyError, wait: 20.seconds, attempts: 5

  def perform(command_id)
    command = Integrations::Medelement::ProviderCommand.find_by(id: command_id)
    return unless ai_booking?(command)

    command.with_lock do
      command.reload
      appointment = command.appointment&.reload
      conversation = appointment&.conversation
      assistant = Captain::Assistant.find_by(id: command.request_snapshot.dig('actor', 'id'), account_id: command.account_id)
      next unless booking_context_valid?(command, appointment, conversation, assistant)

      process_outcome!(command, appointment, conversation, assistant)
    end
  end

  private

  def booking_context_valid?(command, appointment, conversation, assistant)
    appointment && conversation && assistant&.usage_mode == 'external_agent' &&
      conversation.account_id == command.account_id && conversation.contact_id == appointment.contact_id
  end

  def process_outcome!(command, appointment, conversation, assistant)
    if failed_or_unknown?(command)
      notify_staff!(command, conversation, assistant) unless staff_notified?(command)
      return
    end

    return if outcome_recorded?(command)
    return deliver_confirmation!(command, appointment, conversation, assistant) if provider_acknowledged?(command)

    notify_staff!(command, conversation, assistant) if command.create_reception? && command.succeeded?
  end

  def failed_or_unknown?(command)
    command.failed? || command.declined? || command.cancelled? || command.provider_status_unknown?
  end

  def ai_booking?(command)
    (command&.create_reception? || command&.move_reception?) &&
      command.request_snapshot.dig('actor', 'type') == 'Captain::Assistant'
  end

  def outcome_recorded?(command)
    state = command.execution_state.to_h
    state[CUSTOMER_MESSAGE_ID_KEY].present? || state[STAFF_NOTE_ID_KEY].present?
  end

  def staff_notified?(command)
    command.execution_state.to_h[STAFF_NOTE_ID_KEY].present?
  end

  def provider_acknowledged?(command)
    return command.succeeded? && command.provider_reception_code.present? if command.move_reception?

    reference = command.execution_state.to_h['write_provider_reception_code'].presence
    return false if reference.blank?

    command.provider_reception_code.to_s == reference.to_s
  end

  def deliver_confirmation!(command, appointment, conversation, assistant)
    appointment.with_lock do
      next notify_staff!(command, conversation, assistant) unless current_conversation_for_command?(command, appointment, conversation)
      next notify_staff!(command, conversation, assistant) if superseded_before_binding?(command, appointment)
      next notify_staff!(command, conversation, assistant) unless current_confirmed_booking?(command, appointment)

      conversation.with_lock { deliver_pending_confirmation!(command, appointment, conversation, assistant) }
    end
  end

  def current_conversation_for_command?(command, appointment, conversation)
    snapshot_id = command.request_snapshot['conversation_id']
    snapshot_id.present? && snapshot_id.to_s == conversation.id.to_s && appointment.conversation_id == conversation.id &&
      conversation.account_id == command.account_id && conversation.contact_id == appointment.contact_id
  end

  def superseded_before_binding?(command, appointment)
    attributes = appointment.custom_attributes.to_h
    status = Integrations::Medelement::AppointmentProviderStatus
    return false unless attributes[status::ATTRIBUTE_KEY] == status::PENDING && attributes[status::COMMAND_ID_KEY].blank?
    return true if appointment.updated_at > command.created_at

    raise BindingNotReadyError, 'Provider command completed before appointment projection'
  end

  def deliver_pending_confirmation!(command, appointment, conversation, assistant)
    return notify_staff!(command, conversation, assistant) unless conversation.pending? && !human_replied_after_command?(command, conversation)

    message = conversation.messages.create!(
      account_id: command.account_id,
      inbox_id: conversation.inbox_id,
      message_type: :outgoing,
      sender: assistant,
      content: confirmation_content(appointment, command),
      additional_attributes: { medelement_provider_command_id: command.id }
    )
    record_outcome!(command, CUSTOMER_MESSAGE_ID_KEY, message.id)
  end

  def human_replied_after_command?(command, conversation)
    messages = Captain::Conversation::ControlService.messages_scope(conversation).outgoing.where(private: false)
    messages.where('messages.created_at >= ?', command.created_at).find_each.any? do |message|
      message.send(:captain_human_control_candidate?)
    end
  end

  def current_confirmed_booking?(command, appointment)
    appointment_current_for_command?(command, appointment) && provider_snapshot_matches?(command, appointment)
  rescue ArgumentError, KeyError
    false
  end

  def appointment_current_for_command?(command, appointment)
    attributes = appointment.custom_attributes.to_h
    status = Integrations::Medelement::AppointmentProviderStatus
    appointment.status.in?(%w[scheduled confirmed]) &&
      attributes[status::ATTRIBUTE_KEY].in?([status::PENDING, status::SUCCEEDED]) &&
      attributes[status::COMMAND_ID_KEY].to_s == command.id.to_s &&
      attributes[status::COMMAND_IDEMPOTENCY_KEY] == command.idempotency_key &&
      attributes[status::COMMAND_FINGERPRINT_KEY] == command.execution_state.to_h['request_fingerprint'] &&
      attributes[status::COMMAND_DISPATCH_IDENTITY_KEY].to_s == command.execution_state.to_h['dispatch_identity'].to_s
  end

  def provider_snapshot_matches?(command, appointment)
    snapshot = command.request_snapshot
    snapshot['account_id'] == command.account_id &&
      snapshot['appointment_id'] == appointment.id &&
      snapshot['contact_id'] == appointment.contact_id &&
      snapshot['conversation_id'].present? && snapshot['conversation_id'].to_s == appointment.conversation_id.to_s &&
      Time.iso8601(snapshot.fetch('reception').fetch('destination_starts_at')) == appointment.starts_at
  end

  def confirmation_content(appointment, command)
    zone = Time.find_zone(appointment.account.reporting_timezone) || Time.zone
    local_time = appointment.starts_at.in_time_zone(zone)
    key = command.move_reception? ? 'conversations.captain.ai_booking_moved' : 'conversations.captain.ai_booking_confirmed'
    I18n.with_locale(appointment.account.locale) do
      I18n.t(
        key,
        date: local_time.strftime('%d.%m.%Y'),
        time: local_time.strftime('%H:%M'),
        specialist: appointment.resource.name
      )
    end
  end

  def notify_staff!(command, conversation, assistant)
    conversation = Conversation.find_by(id: command.request_snapshot['conversation_id'], account_id: command.account_id,
                                        contact_id: command.contact_id) || conversation
    note_key = if command.execution_state.to_h[CUSTOMER_MESSAGE_ID_KEY].present?
                 'conversations.captain.ai_booking_readback_needs_review'
               else
                 'conversations.captain.ai_booking_needs_review'
               end
    note = conversation.messages.create!(
      account_id: command.account_id,
      inbox_id: conversation.inbox_id,
      message_type: :outgoing,
      private: true,
      sender: assistant,
      content: I18n.with_locale(command.account.locale) { I18n.t(note_key) },
      additional_attributes: { medelement_provider_command_id: command.id }
    )
    record_outcome!(command, STAFF_NOTE_ID_KEY, note.id)
  end

  def record_outcome!(command, key, message_id)
    command.update!(execution_state: command.execution_state.to_h.merge(key => message_id))
  end
end
