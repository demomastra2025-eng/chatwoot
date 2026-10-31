class Telephony::AgentsService
  def initialize(account:)
    @account = account
  end

  def list_remote
    account.telephony_sip_profiles.includes(:user, :provider_connection).recent.map(&:to_telephony_h)
  end

  def set_enabled!(binding:, enabled:)
    if ActiveModel::Type::Boolean.new.cast(enabled)
      if binding.is_a?(Telephony::SipProfile)
        Telephony::ProviderPolicy.ensure_enabled_for_profile!(binding)
      else
        Telephony::ProviderPolicy.ensure_enabled!(binding.provider)
      end
    end

    binding.update!(enabled: enabled, last_synced_at: Time.current)
    {
      'provider' => 'janus_sip',
      'remote_bridge' => false,
      'agent_ref' => binding.agent_ref,
      'enabled' => binding.enabled
    }
  end

  private

  attr_reader :account
end
