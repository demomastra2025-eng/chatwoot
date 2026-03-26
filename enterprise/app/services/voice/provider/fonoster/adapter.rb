class Voice::Provider::Fonoster::Adapter
  def initialize(channel)
    @channel = channel
  end

  def initiate_call(to:, conference_sid: nil, agent_id: nil)
    number_binding = Telephony::NumberBinding.sync_from_voice_channel!(@channel)
    raise Telephony::Error.new(code: 'VOICE_INBOX_NOT_BOUND', message: 'Voice inbox is not bound to a Fonoster number') if number_binding.blank?

    response = Telephony::BridgeClient.new.post(
      '/telephony/calls/outbound',
      {
        from_number_ref: number_binding.number_ref,
        to: to,
        app_ref: number_binding.effective_app_ref,
        metadata: {
          conference_sid: conference_sid,
          chatwoot_user_id: agent_id
        }.compact
      }.compact
    )

    call_ref = response['call_ref'] || response['ref'] || response.dig('payload', 'call_ref') || response.dig('payload', 'ref')

    {
      provider: 'fonoster',
      call_sid: call_ref,
      status: response['status'] || 'ringing',
      call_direction: 'outbound',
      requires_agent_join: false,
      agent_id: agent_id,
      conference_sid: conference_sid,
      bridge_response: response
    }
  end
end
