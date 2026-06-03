class Voice::Provider::Sipuni::Adapter
  CALL_NUMBER_URL = Voice::Provider::Sipuni::CallbackClient::CALL_NUMBER_URL
  REQUEST_TIMEOUT_SECONDS = Voice::Provider::Sipuni::CallbackClient::REQUEST_TIMEOUT_SECONDS

  def initialize(channel)
    @channel = channel
  end

  def initiate_call(to:, conference_sid: nil, agent_id: nil)
    callback = callback_client.call_number(to: to)

    outbound_call_payload(callback, conference_sid, agent_id)
  rescue Telephony::Error
    raise
  rescue StandardError => e
    raise outbound_error(e, to, conference_sid, agent_id)
  end

  private

  attr_reader :channel

  def outbound_call_payload(callback, conference_sid, agent_id)
    {
      provider: 'sipuni',
      call_sid: callback[:callback_id],
      provider_request_ref: callback[:callback_id],
      status: callback[:status] || 'ringing',
      call_direction: 'outbound',
      requires_agent_join: false,
      agent_id: agent_id,
      conference_sid: conference_sid,
      sipuni_response: callback[:response]
    }
  end

  def outbound_error(error, to, conference_sid, agent_id)
    Telephony::Error.new(
      code: 'SIPUNI_OUTBOUND_FAILED',
      message: "Unable to create Sipuni outbound callback: #{error.message}",
      status: :bad_gateway,
      details: {
        provider: 'sipuni',
        phone_number: channel.phone_number,
        to: to,
        conference_sid: conference_sid,
        agent_id: agent_id,
        error_class: error.class.name
      }.compact
    )
  end

  def callback_client
    @callback_client ||= Voice::Provider::Sipuni::CallbackClient.new(channel)
  end
end
