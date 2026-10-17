class Telephony::OperatorBusyService
  class << self
    def busy_user_ids(account:, user_ids:, excluding_telephony_call_ref: nil)
      user_ids = Array(user_ids).compact.map(&:to_i).uniq
      return [] if user_ids.blank?

      sessions = account.telephony_call_sessions.active
      sessions = sessions.where.not(external_call_ref: excluding_telephony_call_ref) if excluding_telephony_call_ref.present?
      rows = sessions.pluck(:agent_binding_id, :direction, :metadata)

      (binding_user_ids(account, rows, user_ids) + profile_user_ids(account, rows, user_ids) +
        claimed_user_ids(rows) + accepted_call_user_ids(account, user_ids)).uniq & user_ids
    end

    private

    def binding_user_ids(account, rows, user_ids)
      binding_ids = rows.filter_map(&:first)
      account.telephony_agent_bindings.where(id: binding_ids, user_id: user_ids).pluck(:user_id)
    end

    def profile_user_ids(account, rows, user_ids)
      profile_ids = rows.filter_map { |_, _, metadata| hash_from(metadata, 'operator_claim')['sip_profile_id'] }
      account.telephony_sip_profiles.human_operator.where(id: profile_ids, user_id: user_ids).pluck(:user_id)
    end

    def claimed_user_ids(rows)
      rows.flat_map do |_, direction, metadata|
        ids = [hash_from(metadata, 'operator_claim')['user_id']]
        if direction == 'outbound'
          ids << hash_from(metadata, 'operator_identity')['user_id']
          ids << hash_from(metadata, 'metadata')['chatwoot_user_id']
        end
        ids.compact.map(&:to_i)
      end
    end

    def accepted_call_user_ids(account, user_ids)
      return [] unless defined?(Call)

      account.calls.active.where(accepted_by_agent_id: user_ids).distinct.pluck(:accepted_by_agent_id)
    end

    def hash_from(value, key)
      value.is_a?(Hash) && value[key].is_a?(Hash) ? value[key] : {}
    end
  end

  def initialize(account:, user: nil, sip_profile: nil, excluding_telephony_call: nil, excluding_whatsapp_call: nil)
    @account = account
    @user = user
    @sip_profile = sip_profile
    @excluding_telephony_call = excluding_telephony_call
    @excluding_whatsapp_call = excluding_whatsapp_call
  end

  def with_lock
    return yield if voice_agent_profile?

    account_user.with_lock do
      raise_busy! if busy?

      yield
    end
  end

  def busy?
    return false if voice_agent_profile?
    return false if user.blank?

    busy_telephony_call.present? || busy_whatsapp_call.present?
  end

  def busy_details
    return nil if voice_agent_profile?
    return {} if user.blank?

    call = busy_telephony_call
    return telephony_call_details(call) if call.present?

    call = busy_whatsapp_call
    return whatsapp_call_details(call) if call.present?

    {}
  end

  private

  attr_reader :account, :user, :sip_profile, :excluding_telephony_call, :excluding_whatsapp_call

  def voice_agent_profile?
    sip_profile.present? && sip_profile.respond_to?(:voice_agent?) && sip_profile.voice_agent?
  end

  def account_user
    @account_user ||= account.account_users.find_by!(user_id: user.id)
  end

  def busy_telephony_call
    return nil if voice_agent_profile? || user.blank?
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
    @busy_telephony_call ||= claimed_profile_call(scope)
  end

  def claimed_profile_call(scope)
    profile_ids = account.telephony_sip_profiles.human_operator.where(user_id: user.id).pluck(:id)
    return if profile_ids.blank?

    scope.where("telephony_call_sessions.metadata -> 'operator_claim' ->> 'sip_profile_id' IN (?)", profile_ids.map(&:to_s)).first
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
