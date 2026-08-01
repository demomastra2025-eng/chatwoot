class Telephony::AiVoice::CallSessionResolver
  def initialize(payload:)
    @payload = payload.deep_stringify_keys
  end

  def call_session
    @call_session ||= resolve_by_call_id || resolve_by_call_ref || resolve_by_conversation_id
  end

  private

  attr_reader :payload

  def resolve_by_call_id
    return if call_id.blank?
    return if scope_account.blank?

    scope_account.telephony_call_sessions.find_by(id: call_id)
  end

  def resolve_by_call_ref
    return if call_ref.blank?
    return if scope_account.blank?

    scope_account.telephony_call_sessions.find_by(external_call_ref: call_ref)
  end

  def resolve_by_conversation_id
    return if conversation_id.blank?
    return if scope_account.blank?

    scope_account.telephony_call_sessions.where(conversation_id: conversation_id).order(updated_at: :desc).first
  end

  def scope_account
    @scope_account ||= begin
      explicit = explicit_account
      raise_account_not_found! if account_id.present? && explicit.blank?

      binding = number_binding
      raise_number_binding_mismatch! if explicit.present? && binding.present? && binding.account_id != explicit.id
      raise_conversation_account_mismatch! if explicit.present? && conversation_record.present? && conversation_record.account_id != explicit.id
      raise_conversation_account_mismatch! if binding.present? && conversation_record.present? && conversation_record.account_id != binding.account_id

      explicit || binding&.account || conversation_record&.account
    end
  end

  def explicit_account
    @explicit_account ||= Account.find_by(id: account_id) if account_id.present?
  end

  def number_binding
    return @number_binding if defined?(@number_binding)

    scope = Telephony::NumberBinding.includes(:account)
    @number_binding = if number_ref.present?
                        scope.find_by(number_ref: number_ref)
                      elsif ingress_number.present?
                        scope.find_by(phone_number: ingress_number)
                      end
  end

  def raise_account_not_found!
    raise Telephony::Error.new(
      code: 'ACCOUNT_NOT_FOUND',
      message: 'account_id does not resolve to an account',
      status: :not_found
    )
  end

  def raise_number_binding_mismatch!
    raise Telephony::Error.new(
      code: 'NUMBER_BINDING_ACCOUNT_MISMATCH',
      message: 'number_ref does not belong to the resolved account',
      status: :unprocessable_content
    )
  end

  def raise_conversation_account_mismatch!
    raise Telephony::Error.new(
      code: 'CONVERSATION_ACCOUNT_MISMATCH',
      message: 'conversation_id does not belong to the resolved account',
      status: :unprocessable_content
    )
  end

  def call_ref
    payload['bridge_call_ref'].presence ||
      payload['bridgeCallRef'].presence ||
      payload['parent_call_ref'].presence ||
      payload['parentCallRef'].presence ||
      payload['call_ref'].presence ||
      payload['callRef'].presence ||
      payload['provider_call_id'].presence ||
      payload['providerCallId'].presence
  end

  def call_id
    raw = payload['call_session_id'].presence || payload['callSessionId'].presence || payload['call_id'].presence || payload['callId'].presence
    raw.to_s if raw.to_s.match?(/\A\d+\z/)
  end

  def conversation_id
    payload['conversation_id'].presence || payload['conversationId'].presence
  end

  def conversation_record
    @conversation_record ||= ::Conversation.find_by(id: conversation_id) if conversation_id.present?
  end

  def account_id
    payload['account_id'].presence || payload['accountId'].presence
  end

  def number_ref
    payload['number_ref'].presence || payload['numberRef'].presence
  end

  def ingress_number
    payload['ingress_number'].presence || payload['ingressNumber'].presence || payload['to_number'].presence || payload['toNumber'].presence ||
      payload['to'].presence
  end
end
