class Voice::Provider::Sipuni::Adapter
  def initialize(channel)
    @channel = channel
  end

  def initiate_call(to:, conference_sid: nil, agent_id: nil)
    raise Telephony::Error.new(
      code: 'SIPUNI_OUTBOUND_NOT_CONFIGURED',
      message: 'Sipuni browser click-to-call requires a confirmed Sipuni call control API contract or a SIP/WebRTC bridge',
      status: :unprocessable_content,
      details: {
        provider: 'sipuni',
        phone_number: channel.phone_number,
        to: to,
        conference_sid: conference_sid,
        agent_id: agent_id
      }.compact
    )
  end

  private

  attr_reader :channel
end
