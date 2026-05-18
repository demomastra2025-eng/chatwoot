class Internal::Voice::RecordingsController < Internal::Voice::Ai::BaseController
  def ready
    result = Telephony::RecordingImportReadyService.new(
      payload: request_payload,
      headers: request_event_headers
    ).perform

    render json: result, status: :accepted
  end

  private

  # Fonoster/bridge delivers operator recordings after the call; AI runtime recordings still use
  # the voice token path. Accept both token families for this endpoint only.
  def internal_voice_tokens
    super + [
      ENV.fetch('TELEPHONY_BRIDGE_ACCESS_TOKEN', '').presence,
      ENV.fetch('TELEPHONY_BRIDGE_ONELINK_ACCESS_TOKEN', '').presence,
      ENV.fetch('TELEPHONY_BRIDGE_SHARED_SECRET', '').presence
    ].compact
  end
end
