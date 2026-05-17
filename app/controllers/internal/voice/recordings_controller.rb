class Internal::Voice::RecordingsController < Internal::Voice::Ai::BaseController
  def ready
    result = Telephony::RecordingImportReadyService.new(
      payload: request_payload,
      headers: request_event_headers
    ).perform

    render json: result, status: :accepted
  end
end
