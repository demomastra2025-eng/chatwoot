# frozen_string_literal: true

class Reminders::IncomingReplyDecisionService
  CONFIDENCE_THRESHOLD = 0.80
  STOP_CONFIDENCE_THRESHOLD = 0.85

  CRITERIA = {
    'confirm_appointment' => 'The customer confirms they will attend the appointment or agrees with the scheduled visit (e.g., "Да, приду", "Буду вовремя", "Ок, спасибо", "Келемін", "Жақсы").',
    'reschedule_or_cancel' => 'The customer wants to cancel, postpone, or reschedule the visit to another time/day (e.g., "Не смогу прийти", "Давайте перенесем", "Отмените", "Басқа уақытқа ауыстырайық").',
    'question' => 'The customer asks a question or requests details (e.g., price, preparation, address, doctor name, "А сколько стоит?", "Как подготовиться?", "По какому адресу?").',
    'stop_or_negative' => 'The customer expresses irritation, asks to stop messaging/spamming, or refuses further contact (e.g., "Не пишите мне больше", "Удалите номер", "Отстаньте", "Хватит слать рассылку").'
  }.freeze

  INSTRUCTIONS = 'Classify the customer reply to an outbound clinic reminder, confirmation request, or follow-up touch into one of the four intent categories.'

  Result = Struct.new(:choice, :confidence, :model, :provider, :request_id, keyword_init: true) do
    def confident?(threshold = CONFIDENCE_THRESHOLD)
      choice.present? && (confidence.nil? || confidence >= threshold)
    end
  end

  def initialize(account:, conversation:, message:, cancelled_reminders_count: 0, override_text: nil, **_rest)
    @account = account
    @conversation = conversation
    @message = message
    @cancelled_reminders_count = cancelled_reminders_count.to_i
    @override_text = override_text
  end

  def perform
    return nil unless eligible_message?
    return nil unless outbound_context_present?

    model = Llm::Config.model_for(
      feature: 'outbound_reply_classification',
      account: account,
      fallback: 'perplexity/pplx-decider-flash-v1.2'
    ).presence || 'perplexity/pplx-decider-flash-v1.2'
    return nil unless Llm::OpenRouterDecisionClient.supported_model?(model)

    decision = Llm::Runtime.decide(
      feature: :outbound_reply_classification,
      account: account,
      model: model,
      input: build_state,
      options: {
        decision_criteria: CRITERIA,
        decision_instructions: INSTRUCTIONS
      }
    )

    Result.new(
      choice: decision.choice,
      confidence: decision.confidence,
      model: decision.model,
      provider: decision.provider,
      request_id: decision.request_id
    )
  rescue StandardError => e
    Rails.logger.warn("[Reminders::IncomingReplyDecisionService] Decision failed: #{e.class}: #{e.message}")
    nil
  end

  def apply_side_effects!
    result = perform
    return nil unless result&.confident?

    record_message_decision_metadata!(result)

    case result.choice
    when 'stop_or_negative'
      apply_stop_or_negative!(result) if result.confident?(STOP_CONFIDENCE_THRESHOLD)
    when 'confirm_appointment'
      apply_appointment_confirmation!(result)
    end

    result
  end

  private

  attr_reader :account, :conversation, :message, :cancelled_reminders_count, :override_text

  def eligible_message?
    message.present? &&
      conversation.present? &&
      account.present? &&
      message.incoming? &&
      !message.private? &&
      (override_text.presence || message.content.to_s.strip).present?
  end

  def outbound_context_present?
    cancelled_reminders_count.positive? ||
      open_reminders_exist? ||
      recent_cancelled_reminder_exists? ||
      pending_confirmation_exists?
  end

  def open_reminders_exist?
    account.reminders.open_statuses.where(conversation_id: conversation.id).exists?
  end

  def recent_cancelled_reminder_exists?
    account.reminders
           .where(conversation_id: conversation.id, status: :cancelled)
           .where('updated_at >= ?', 2.minutes.ago)
           .exists?
  end

  def pending_confirmation_exists?
    defined?(ConfirmationRequest) &&
      ConfirmationRequest.where(account_id: account.id, conversation_id: conversation.id, status: :pending).exists?
  end

  def build_state
    {
      'last_outbound_message' => last_outbound_message_text,
      'customer_reply' => message.content.to_s.squish.truncate(600),
      'upcoming_appointments_count' => upcoming_appointments.size
    }.compact
  end

  def last_outbound_message_text
    outbound = conversation.messages
                           .where(private: false, message_type: %i[outgoing template])
                           .where('id < ?', message.id)
                           .order(id: :desc)
                           .first
    outbound&.content.to_s.squish.truncate(500).presence
  end

  def upcoming_appointments
    @upcoming_appointments ||= account.scheduling_appointments
                                      .active_statuses
                                      .where(conversation_id: conversation.id)
                                      .where('starts_at >= ?', 1.hour.ago)
                                      .order(:starts_at)
                                      .limit(5)
                                      .to_a
  end

  def record_message_decision_metadata!(result)
    attrs = message.content_attributes.to_h.deep_dup
    attrs['outbound_reply_decision'] = result.choice
    attrs['outbound_reply_decision_confidence'] = result.confidence
    attrs['suppress_captain_auto_reply'] = true if result.choice == 'stop_or_negative' && result.confident?(STOP_CONFIDENCE_THRESHOLD)
    message.update_columns(content_attributes: attrs) if message.persisted?
  end

  def apply_stop_or_negative!(_result)
    contact = conversation.contact
    if contact.present?
      custom = contact.custom_attributes.to_h.deep_dup
      custom['outbound_opt_out'] = true
      custom['outbound_opt_out_at'] = Time.current.iso8601
      contact.update_columns(custom_attributes: custom, updated_at: Time.current)
    end

    account.reminders.open_statuses.where(conversation_id: conversation.id).find_each do |reminder|
      reminder.update(status: :cancelled, last_error: 'cancelled_by_customer_stop_reply')
    end
  end

  def apply_appointment_confirmation!(result)
    scheduled = upcoming_appointments.select { |apt| apt.status == 'scheduled' }
    return if scheduled.empty?

    target_date = scheduled.first.starts_at.in_time_zone('Asia/Almaty').to_date
    same_day = scheduled.select { |apt| apt.starts_at.in_time_zone('Asia/Almaty').to_date == target_date }
    same_day.each do |appointment|
      appointment.update(
        status: 'confirmed',
        custom_attributes: appointment.custom_attributes.to_h.merge(
          'confirmed_via_decision_ai_at' => Time.current.iso8601,
          'confirmed_via_decision_confidence' => result.confidence
        )
      )
    end
  end
end
