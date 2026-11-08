# frozen_string_literal: true

class Confirmations::InboundTextResolver
  CONFIRM_PATTERN = /\b(yes|y|ok|okay|confirm|confirmed|thumbs\s*up|checkmark)\b|(^|[\s[:punct:]])(да|иә|подтверждаю|подтвердить|приду|келемін|жақсы|согласен|согласна|ок|окей|хорошо)(\s|[[:punct:]]|$)/i
  DECLINE_PATTERN = /\b(no|nope|decline|declined|cancel|thumbs\s*down)\b|(^|[\s[:punct:]])(нет|жоқ|отмена|отменить|отмените|не подтверждаю|не смогу|не приду)(\s|[[:punct:]]|$)/i
  RESCHEDULE_PATTERN = /(reschedule|another time|перенести|перенос|другое время|другую дату|перезапис)/i

  POSITIVE_EMOJI_PATTERN = /\A[\s\p{Punct}]*(👍[\p{Emoji_Modifier}]*|✅|☑️|✔️|👌[\p{Emoji_Modifier}]*|❤️|♥️|🙏[\p{Emoji_Modifier}]*|🤝|➕|\+|💯)+[\s\p{Punct}]*\z/u
  NEGATIVE_EMOJI_PATTERN = /\A[\s\p{Punct}]*(👎[\p{Emoji_Modifier}]*|❌|✖️|🚫)+[\s\p{Punct}]*\z/u

  SPOOFED_BUTTON_LABELS = %w[подтвердить].freeze

  def initialize(account:, conversation:, message:)
    @account = account
    @conversation = conversation
    @message = message
  end

  def perform
    return result(false, reason: 'no_pending_request') if expired_reply_context?

    @effective_text = Confirmations::AttachmentTextExtractor.extract(message).to_s
    return result(false, reason: 'button_payload_required') if spoofed_button_label_reply?
    return result(false, reason: request_missing_reason) if pending_requests_for_context.empty?
    return result(false, reason: 'ambiguous') if @effective_text.blank?

    classification = classify(@effective_text) || classify_with_decision_model(@effective_text)
    return result(false, reason: 'ambiguous') if classification.blank?

    decision = classification.fetch(:decision)

    # For "Я не приду" / decline / reschedule when the patient has 2+ upcoming appointments
    # and did not quote a specific message: never silently cancel just 1 out of 4 appointments
    # or wipe all 4 without asking — let the assistant ask "Cancel all 4 or a specific one?"
    return result(false, reason: 'multiple_upcoming_appointments') if ambiguous_appointments_for_decline?(decision)

    target_requests = target_requests_for_decision(decision)
    return result(false, reason: request_missing_reason) if target_requests.empty?

    target_requests.each do |req|
      Confirmations::ResolveService.new(
        account: account,
        confirmation_request: req,
        decision: decision,
        source: classification.fetch(:source, 'text'),
        message: message,
        confidence: classification.fetch(:confidence),
        metadata: { 'resolver' => classification.fetch(:resolver, 'deterministic_text') }
      ).perform
    end

    # If the patient confirmed ("Ок" / "Да" / "Приду" / 👍), also confirm any other scheduled appointments on the same day
    confirm_same_day_scheduled_appointments! if decision == 'confirmed' && reply_context_delivery.blank?

    result(
      true,
      decision: decision,
      confidence: classification.fetch(:confidence),
      confirmation_request_id: target_requests.first.id,
      resolved_count: target_requests.size
    )
  end

  private

  attr_reader :account, :conversation, :message

  def pending_requests_for_context
    return @pending_requests_for_context if defined?(@pending_requests_for_context)

    if reply_context_delivery.present?
      req = pending_scope.find_by(delivery_message_id: reply_context_delivery.id)
      return @pending_requests_for_context = req ? [req] : []
    end

    @pending_requests_for_context = pending_scope.latest_first.to_a
  end

  def target_requests_for_decision(decision)
    requests = pending_requests_for_context
    requests = requests.reject { |req| req.reminder&.confirm_appointment_on_reply? } if decision != 'confirmed'
    return [] if requests.empty?
    return requests if requests.one?

    # When there are multiple pending confirmation requests (e.g. 4 appointments today):
    # - On "Ок" ('confirmed'), confirm all pending requests!
    # - On 'declined' / 'reschedule_requested', do not guess which one — require disambiguation.
    if decision == 'confirmed'
      requests
    else
      @ambiguous_pending_requests = true
      []
    end
  end

  def pending_request
    pending_requests_for_context.first
  end

  def reply_context_delivery
    return @reply_context_delivery if defined?(@reply_context_delivery)

    external_id = message.content_attributes.to_h['in_reply_to_external_id']
    return @reply_context_delivery = nil if external_id.blank?

    @reply_context_delivery = Message.find_by(
      account_id: account.id,
      inbox_id: conversation.inbox_id,
      conversation_id: conversation.id,
      source_id: external_id
    )
  end

  def pending_scope
    ConfirmationRequest
      .where(account_id: account.id, conversation_id: conversation.id, inbox_id: conversation.inbox_id)
      .active_pending
  end

  def expired_reply_context?
    return false if reply_context_delivery.blank?

    req = ConfirmationRequest.find_by(
      account_id: account.id,
      conversation_id: conversation.id,
      inbox_id: conversation.inbox_id,
      delivery_message_id: reply_context_delivery.id
    )
    req.present? && req.past_due?
  end

  def spoofed_button_label_reply?
    normalized = @effective_text.to_s.strip.downcase
    return false unless SPOOFED_BUTTON_LABELS.include?(normalized)

    if reply_context_delivery.present?
      button_only_pending_scope.exists?(delivery_message_id: reply_context_delivery.id)
    else
      button_only_pending_scope.exists? && !pending_scope.text_resolvable.exists?
    end
  end

  def request_missing_reason
    return 'button_payload_required' if button_only_pending_scope.exists?
    return 'multiple_pending_requests' if @ambiguous_pending_requests || pending_requests_for_context.many?

    'no_pending_request'
  end

  def button_only_pending_scope
    ConfirmationRequest
      .where(account_id: account.id, conversation_id: conversation.id, inbox_id: conversation.inbox_id)
      .button_only_response
      .active_pending
  end

  def ambiguous_appointments_for_decline?(decision)
    return false unless decision.to_s.in?(%w[declined reschedule_requested])
    return false if reply_context_delivery.present?

    upcoming_appointments_scope.limit(2).count >= 2
  end

  def confirm_same_day_scheduled_appointments!
    scheduled = upcoming_appointments_scope.where(status: 'scheduled').to_a
    return if scheduled.empty?

    target_date = scheduled.first.starts_at.in_time_zone('Asia/Almaty').to_date
    same_day = scheduled.select { |apt| apt.starts_at.in_time_zone('Asia/Almaty').to_date == target_date }
    same_day.each { |apt| apt.update!(status: 'confirmed') }
  end

  def upcoming_appointments_scope
    Scheduling::Appointment
      .where(account_id: account.id)
      .where('conversation_id = :cid OR contact_id = :contact_id',
             cid: conversation.id, contact_id: conversation.contact_id)
      .where(status: %w[scheduled confirmed])
      .where('starts_at >= ?', 1.hour.ago)
      .order(:starts_at)
  end

  def classify_with_decision_model(effective_text = nil)
    return nil unless defined?(Reminders::IncomingReplyDecisionService)

    ai_result = Reminders::IncomingReplyDecisionService.new(
      account: account,
      conversation: conversation,
      message: message,
      confirmation_request: pending_request,
      override_text: effective_text
    ).perform
    return nil unless ai_result&.confident?

    mapped = case ai_result.choice
             when 'confirm_appointment' then 'confirmed'
             when 'reschedule_or_cancel' then 'reschedule_requested'
             when 'stop_or_negative' then 'declined'
             end
    return nil if mapped.blank?

    {
      decision: mapped,
      confidence: ai_result.confidence || 0.85,
      source: 'ai',
      resolver: 'decision_model'
    }
  end

  def classify(text)
    normalized = text.to_s.strip
    return nil if normalized.blank?
    return { decision: 'confirmed', confidence: 0.96 } if normalized.match?(POSITIVE_EMOJI_PATTERN)
    return { decision: 'declined', confidence: 0.96 } if normalized.match?(NEGATIVE_EMOJI_PATTERN)
    return { decision: 'reschedule_requested', confidence: 0.94 } if normalized.match?(RESCHEDULE_PATTERN)
    return { decision: 'declined', confidence: 0.93 } if normalized.match?(DECLINE_PATTERN)
    return { decision: 'confirmed', confidence: 0.93 } if normalized.match?(CONFIRM_PATTERN)

    nil
  end

  def result(handled, payload = {})
    { handled: handled }.merge(payload)
  end
end
