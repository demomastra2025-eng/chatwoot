# frozen_string_literal: true

class Confirmations::InboundTextResolver
  CONFIRM_PATTERN = /\b(yes|y|ok|okay|confirm|confirmed)\b|(^|\s)(да|иә|подтверждаю|подтвердить|согласен|согласна|ок|хорошо)(\s|$)/i
  DECLINE_PATTERN = /\b(no|nope|decline|declined|cancel)\b|(^|\s)(нет|жоқ|отмена|отменить|отмените|не подтверждаю|не смогу)(\s|$)/i
  RESCHEDULE_PATTERN = /(reschedule|another time|перенести|перенос|другое время|другую дату|перезапис)/i

  def initialize(account:, conversation:, message:)
    @account = account
    @conversation = conversation
    @message = message
  end

  def perform
    return result(false, reason: request_missing_reason) if pending_request.blank?

    classification = classify(message.content.to_s)
    return result(false, reason: 'ambiguous') if classification.blank?

    Confirmations::ResolveService.new(
      account: account,
      confirmation_request: pending_request,
      decision: classification.fetch(:decision),
      source: 'text',
      message: message,
      confidence: classification.fetch(:confidence),
      metadata: { 'resolver' => 'deterministic_text' }
    ).perform

    result(
      true,
      decision: classification.fetch(:decision),
      confidence: classification.fetch(:confidence),
      confirmation_request_id: pending_request.id
    )
  end

  private

  attr_reader :account, :conversation, :message

  def pending_request
    return @pending_request if defined?(@pending_request)

    @pending_request = if button_only_reply_context?
                         nil
                       else
                         request_from_reply_context || sole_pending_request
                       end
  end

  def request_from_reply_context
    return if reply_context_delivery.blank?

    pending_scope.find_by(delivery_message_id: reply_context_delivery.id)
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

  def sole_pending_request
    requests = pending_scope.latest_first.limit(2).to_a
    @ambiguous_pending_requests = requests.many?
    requests.one? ? requests.first : nil
  end

  def pending_scope
    ConfirmationRequest
      .where(account_id: account.id, conversation_id: conversation.id, inbox_id: conversation.inbox_id)
      .active_pending
      .text_resolvable
  end

  def request_missing_reason
    return 'button_payload_required' if button_only_request_exists?

    @ambiguous_pending_requests ? 'ambiguous' : 'no_pending_request'
  end

  def button_only_request_exists?
    button_only_pending_scope.exists?
  end

  def button_only_reply_context?
    reply_context_delivery.present? && button_only_request_scope.exists?(delivery_message_id: reply_context_delivery.id)
  end

  def button_only_pending_scope
    button_only_request_scope.active_pending
  end

  def button_only_request_scope
    ConfirmationRequest
      .where(account_id: account.id, conversation_id: conversation.id, inbox_id: conversation.inbox_id)
      .button_only_response
  end

  def classify(text)
    normalized = text.to_s.strip
    return { decision: 'reschedule_requested', confidence: 0.94 } if normalized.match?(RESCHEDULE_PATTERN)
    return { decision: 'declined', confidence: 0.93 } if normalized.match?(DECLINE_PATTERN)
    return { decision: 'confirmed', confidence: 0.93 } if normalized.match?(CONFIRM_PATTERN)

    nil
  end

  def result(handled, payload = {})
    { handled: handled }.merge(payload)
  end
end
