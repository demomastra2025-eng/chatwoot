class Telephony::AgentsService
  def initialize(account:, bridge_client: nil)
    @account = account
    @bridge_client = bridge_client || Telephony::BridgeClient.new(account_id: account.id)
  end

  def list_remote
    bridge_client.get('/telephony/agents')
  end

  def set_enabled!(binding:, enabled:)
    response = bridge_client.post("/telephony/agents/#{binding.agent_ref}/enabled", { enabled: enabled })
    binding.update!(enabled: enabled, last_synced_at: Time.current)
    response
  end

  private

  attr_reader :account, :bridge_client
end
