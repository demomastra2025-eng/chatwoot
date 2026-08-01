class Internal::Voice::Ai::ToolsController < Internal::Voice::Ai::BaseController
  def create
    payload = request_payload
    payload['idempotency_key'] ||= request_event_headers[:idempotency_key]
    payload['tool_capability'] ||= request.headers['X-OneLink-Voice-Tool-Capability'].to_s.presence
    result = Telephony::AiVoice::ToolExecutionService.new(
      tool_name: params[:name],
      payload: payload
    ).perform

    render json: { result: result }
  rescue Telephony::AiVoice::ToolDispatchService::UnknownToolError => e
    render json: { error: 'tool_not_found', message: e.message }, status: :not_found
  end
end
