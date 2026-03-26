class Webhooks::WhatsappWebController < ActionController::API
  before_action :set_channel
  before_action :verify_signature!

  def process_payload
    Channels::WhatsappWeb::ProcessWebhookEventJob.perform_later(@channel.id, request_payload.deep_stringify_keys)

    head :ok
  rescue StandardError => e
    Rails.logger.error("[WHATSAPP WEB] Webhook processing failed: #{e.message}")
    render json: { error: e.message }, status: error_status_for(e)
  end

  private

  def set_channel
    @channel = Channel::WhatsappWeb.find_by!(webhook_identifier: params[:webhook_identifier])
  end

  def verify_signature!
    token = request.headers['Authorization'].to_s.remove(/\ABearer\s+/)
    render json: { error: 'Unauthorized' }, status: :unauthorized and return if token.blank?

    JWT.decode(token, @channel.webhook_secret, true, algorithm: 'HS256')
  rescue JWT::DecodeError, JWT::VerificationError
    render json: { error: 'Unauthorized' }, status: :unauthorized
  end

  def request_payload
    params.to_unsafe_hash.except('controller', 'action', 'webhook_identifier').deep_symbolize_keys
  end

  def error_status_for(error)
    transient_queue_error?(error) ? :service_unavailable : :internal_server_error
  end

  def transient_queue_error?(error)
    exception_chain(error).any? do |exception|
      exception.class.name == ActiveJob::EnqueueError.name ||
        exception.class.name.start_with?('RedisClient::', 'Redis::')
    end
  end

  def exception_chain(error)
    [].tap do |chain|
      current = error
      while current.present? && !chain.include?(current)
        chain << current
        current = current.cause
      end
    end
  end
end
