class Internal::Voice::Ai::ToolsController < Internal::Voice::Ai::BaseController
  def create
    result = Telephony::AiVoice::ToolDispatchService.new(
      tool_name: params[:name],
      payload: request_payload
    ).perform

    render json: { result: result }
  rescue Telephony::AiVoice::ToolDispatchService::UnknownToolError => e
    render json: { error: 'tool_not_found', message: e.message }, status: :not_found
  end
end
