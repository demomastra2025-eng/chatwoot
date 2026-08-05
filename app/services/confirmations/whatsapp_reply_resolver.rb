# frozen_string_literal: true

class Confirmations::WhatsappReplyResolver
  PAYLOAD_PATTERN = /\Aconfirmation:(?<token>[^:]+):(?<decision>confirmed|declined|reschedule_requested)\z/
  DECISION_ALIASES = {
    'confirm' => 'confirmed',
    'confirmed' => 'confirmed',
    'yes' => 'confirmed',
    'y' => 'confirmed',
    'ok' => 'confirmed',
    'да' => 'confirmed',
    'иә' => 'confirmed',
    'подтвердить' => 'confirmed',
    'подтверждаю' => 'confirmed',
    'согласен' => 'confirmed',
    'согласна' => 'confirmed',
    'decline' => 'declined',
    'declined' => 'declined',
    'cancel' => 'declined',
    'no' => 'declined',
    'нет' => 'declined',
    'жоқ' => 'declined',
    'отменить' => 'declined',
    'отмена' => 'declined',
    'reschedule' => 'reschedule_requested',
    'reschedule_requested' => 'reschedule_requested',
    'перенести' => 'reschedule_requested',
    'перенос' => 'reschedule_requested'
  }.freeze

  def initialize(account:, conversation:, message:)
    @account = account
    @conversation = conversation
    @message = message
  end

  def perform
    return text_result unless button_reply?
    return result(false, reason: request_missing_reason) if confirmation_request.blank?
    return result(false, reason: 'ambiguous') if decision.blank?

    Confirmations::ResolveService.new(
      account: account,
      confirmation_request: confirmation_request,
      decision: decision,
      source: 'button',
      message: message,
      confidence: 1.0,
      metadata: resolution_metadata
    ).perform

    result(true, decision: decision, confirmation_request_id: confirmation_request.id)
  end

  private

  attr_reader :account, :conversation, :message

  def text_result
    Confirmations::InboundTextResolver.new(account: account, conversation: conversation, message: message).perform
  end

  def button_reply?
    interactive_reply_id.present? || button_payload.present? || button_text.present?
  end

  def confirmation_request
    return @confirmation_request if defined?(@confirmation_request)

    @confirmation_request = if payload_match.present?
                              request_from_payload
                            elsif button_only_reply_context?
                              nil
                            else
                              request_from_reply_context || sole_pending_request
                            end
  end

  def request_from_payload
    return if payload_match.blank?

    ConfirmationRequest
      .where(account_id: account.id, token: payload_match[:token])
      .where(conversation_id: conversation.id, inbox_id: conversation.inbox_id)
      .active_pending
      .first
  end

  def request_from_reply_context
    return if reply_context_delivery.blank?

    pending_scope.find_by(delivery_message_id: reply_context_delivery.id)
  end

  def reply_context_delivery
    return @reply_context_delivery if defined?(@reply_context_delivery)
    return @reply_context_delivery = nil if in_reply_to_external_id.blank?

    @reply_context_delivery = Message.find_by(
      account_id: account.id,
      inbox_id: conversation.inbox_id,
      conversation_id: conversation.id,
      source_id: in_reply_to_external_id
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

  def decision
    @decision ||= payload_match&.[](:decision) ||
                  decision_from_text(button_payload) ||
                  decision_from_text(button_text) ||
                  decision_from_text(message.content)
  end

  def payload_match
    @payload_match ||= PAYLOAD_PATTERN.match(interactive_reply_id.to_s.strip) || PAYLOAD_PATTERN.match(button_payload.to_s.strip)
  end

  def decision_from_text(value)
    normalized = value.to_s.squish.downcase
    DECISION_ALIASES[normalized]
  end

  def resolution_metadata
    {
      'resolver' => 'whatsapp_button',
      'message_source_id' => message.source_id,
      'channel_type' => message.inbox&.channel_type,
      'provider' => message.inbox&.channel&.try(:provider),
      'whatsapp_message_type' => content_attributes['whatsapp_message_type'],
      'interactive_reply_type' => content_attributes['interactive_reply_type'],
      'interactive_reply_id' => interactive_reply_id,
      'interactive_reply_title' => content_attributes['interactive_reply_title'],
      'button_payload' => button_payload,
      'button_text' => button_text,
      'decision' => decision
    }.compact
  end

  def interactive_reply_id
    content_attributes['interactive_reply_id']
  end

  def button_payload
    content_attributes['button_payload']
  end

  def button_text
    content_attributes['button_text']
  end

  def in_reply_to_external_id
    content_attributes['in_reply_to_external_id']
  end

  def content_attributes
    @content_attributes ||= message.content_attributes.to_h
  end

  def result(handled, payload = {})
    { handled: handled }.merge(payload)
  end
end
