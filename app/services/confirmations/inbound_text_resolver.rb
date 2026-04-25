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
    return result(false, reason: 'no_pending_request') if pending_request.blank?

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
    @pending_request ||= ConfirmationRequest
                         .where(account_id: account.id, conversation_id: conversation.id)
                         .active_pending
                         .latest_first
                         .first
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
