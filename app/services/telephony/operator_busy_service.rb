class Telephony::OperatorBusyService
  def initialize(account:, user:, excluding_telephony_call: nil, excluding_whatsapp_call: nil)
    @account = account
    @user = user
    @excluding_telephony_call = excluding_telephony_call
    @excluding_whatsapp_call = excluding_whatsapp_call
  end

  def with_lock
    account_user.with_lock do
      raise_busy! if busy?

      yield
    end
  end

  def busy?
    busy_telephony_call.present? || busy_whatsapp_call.present?
  end

  def busy_details
    call = busy_telephony_call
    return telephony_call_details(call) if call.present?

    call = busy_whatsapp_call
    return whatsapp_call_details(call) if call.present?

    {}
  end

  private

  attr_reader :account, :user, :excluding_telephony_call, :excluding_whatsapp_call

  def account_user
    @account_user ||= account.account_users.find_by!(user_id: user.id)
  end

  def busy_telephony_call
    return @busy_telephony_call if defined?(@busy_telephony_call)

    scope = account.telephony_call_sessions.active
    scope = scope.where.not(id: excluding_telephony_call.id) if excluding_telephony_call.present?

    binding_ids = account.telephony_agent_bindings.where(user_id: user.id).select(:id)
    @busy_telephony_call = scope.where(agent_binding_id: binding_ids).first
    @busy_telephony_call ||= scope.where(
      <<~SQL.squish,
        telephony_call_sessions.metadata -> 'operator_claim' ->> 'user_id' = :user_id OR
        (
          telephony_call_sessions.direction = 'outbound' AND
          (
            telephony_call_sessions.metadata -> 'operator_identity' ->> 'user_id' = :user_id OR
            telephony_call_sessions.metadata -> 'metadata' ->> 'chatwoot_user_id' = :user_id
          )
        )
      SQL
      user_id: user.id.to_s
    ).first
  end

  def busy_whatsapp_call
    return @busy_whatsapp_call if defined?(@busy_whatsapp_call)
    return @busy_whatsapp_call = nil unless defined?(Call)

    scope = account.calls.active_for_agent(user.id)
    scope = scope.where.not(id: excluding_whatsapp_call.id) if excluding_whatsapp_call.present?
    @busy_whatsapp_call = scope.first
  end

  def raise_busy!
    raise Telephony::Error.new(
      code: 'OPERATOR_BUSY',
      message: 'Operator already has an active call',
      status: :conflict,
      details: busy_details
    )
  end

  def telephony_call_details(call)
    {
      channel: 'voice',
      call_ref: call.external_call_ref,
      status: call.canonical_status
    }
  end

  def whatsapp_call_details(call)
    {
      channel: 'whatsapp',
      call_id: call.provider_call_id,
      status: call.status
    }
  end
end
