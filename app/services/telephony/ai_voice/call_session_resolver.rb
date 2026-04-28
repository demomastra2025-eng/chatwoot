class Telephony::AiVoice::CallSessionResolver
  def initialize(payload:)
    @payload = payload.deep_stringify_keys
  end

  def call_session
    @call_session ||= resolve_by_call_ref || resolve_by_conversation_id
  end

  private

  attr_reader :payload

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

      explicit || binding&.account
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

  def call_ref
    payload['call_ref'].presence || payload['callRef'].presence
  end

  def conversation_id
    payload['conversation_id'].presence || payload['conversationId'].presence
  end

  def account_id
    payload['account_id'].presence || payload['accountId'].presence
  end

  def number_ref
    payload['number_ref'].presence || payload['numberRef'].presence
  end

  def ingress_number
    payload['ingress_number'].presence || payload['ingressNumber'].presence || payload['to_number'].presence || payload['toNumber'].presence
  end
end
