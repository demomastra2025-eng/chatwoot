class Internal::Voice::Ai::ContextController < Internal::Voice::Ai::BaseController
  def show
    render json: Telephony::AiVoice::ContextBuilder.new(
      params: request_payload,
      runtime_capabilities: request.headers['X-OneLink-Voice-Capabilities'].to_s.split(',')
    ).perform
  end

  def create
    show
  end
end
