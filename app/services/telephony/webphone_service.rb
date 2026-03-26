class Telephony::WebphoneService
  def initialize(account:, bridge_client: Telephony::BridgeClient.new)
    @account = account
    @bridge_client = bridge_client
  end

  def token_for(user:, inbox: nil)
    agent_binding = account.telephony_agent_bindings.find_by(user_id: user.id)
    response = bridge_client.post(
      '/telephony/webphone/token',
      {
        chatwoot_user_id: user.id,
        agent_ref: agent_binding&.agent_ref,
        inbox_id: inbox&.id,
        number_ref: inbox&.telephony_number_binding&.number_ref
      }.compact
    )

    response = response.deep_dup
    response['provider'] ||= inbox&.channel&.provider || 'fonoster'
    response['agent_ref'] ||= agent_binding&.agent_ref
    response['calling_supported'] = bridge_calling_supported?(response)
    response
  end

  private

  attr_reader :account, :bridge_client

  def bridge_calling_supported?(response)
    provider = response['provider'].presence || 'fonoster'
    return false unless provider == 'twilio'

    return response['calling_supported'] unless response['calling_supported'].nil?

    true
  end
end
