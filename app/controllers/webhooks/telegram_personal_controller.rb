class Webhooks::TelegramPersonalController < ActionController::API
  HISTORY_EVENTS = %w[message.imported contact.imported].freeze

  before_action :set_channel
  before_action :verify_signature!

  def process_payload
    job_class.perform_later(@channel.id, request_payload.deep_stringify_keys)
    head :ok
  rescue StandardError => e
    Rails.logger.error("[TELEGRAM PERSONAL] Webhook processing failed: #{e.message}")
    render json: { error: e.message }, status: error_status_for(e)
  end

  private

  def set_channel
    @channel = Channel::TelegramPersonal.find_by!(webhook_identifier: params[:webhook_identifier])
  end

  def verify_signature!
    token = request.headers['Authorization'].to_s.remove(/\ABearer\s+/)
    render json: { error: 'Unauthorized' }, status: :unauthorized and return if token.blank?

    JWT.decode(token, @channel.webhook_secret, true, algorithm: 'HS256')
  rescue JWT::DecodeError, JWT::VerificationError
    render json: { error: 'Unauthorized' }, status: :unauthorized
  end

  def request_payload
    {
      event: params[:event],
      telegram_personal: {
        data: webhook_data
      }
    }
  end

  def webhook_data
    raw_data = params[:data]
    return raw_data.to_unsafe_h.deep_symbolize_keys if raw_data.respond_to?(:to_unsafe_h)
    return raw_data.deep_symbolize_keys if raw_data.is_a?(Hash)

    params.to_unsafe_hash
          .except('controller', 'action', 'webhook_identifier', 'event', 'telegram_personal')
          .deep_symbolize_keys
  end

  def job_class
    return Channels::TelegramPersonal::ProcessHistoryWebhookEventJob if HISTORY_EVENTS.include?(params[:event].to_s)

    Channels::TelegramPersonal::ProcessWebhookEventJob
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
