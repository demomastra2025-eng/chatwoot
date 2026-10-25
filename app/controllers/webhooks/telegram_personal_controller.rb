class Webhooks::TelegramPersonalController < ActionController::API
  HISTORY_EVENTS = %w[message.imported contact.imported].freeze
  # The arguments of a job stay in Redis, and in the retry and dead sets (Sidekiq Web) and Sentry when it fails: the session
  # string of a runtime snapshot is stored here and now instead, and the hash of a pending login code (which the gateway keeps
  # for itself) is dropped
  SECRET_DATA_KEYS = %w[string_session pending_phone_code_hash].freeze

  before_action :set_channel
  before_action :verify_signature!

  def process_payload
    return skip_service_account_event if TelegramPersonal::ServiceAccount.event?(params[:event], webhook_data)

    store_session!
    job_class.perform_later(@channel.id, job_payload)
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

  # A login code of Telegram's own service account never reaches the queue (TelegramPersonal::ServiceAccount)
  def skip_service_account_event
    TelegramPersonal::ServiceAccount.log_skipped(params[:event], @channel)
    @channel.update_column(:last_synced_at, Time.current) # rubocop:disable Rails/SkipsModelValidations
    head :ok
  end

  # The session of a runtime snapshot, as TelegramPersonal::IncomingEventService applied it: a blank one never clears it
  def store_session!
    return unless params[:event].to_s == 'runtime.updated'

    session = webhook_data[:string_session].to_s.presence
    return if session.blank? || session == @channel.string_session

    @channel.update!(string_session: session)
  end

  def job_payload
    payload = request_payload.deep_stringify_keys
    data = payload.dig('telegram_personal', 'data').except(*SECRET_DATA_KEYS)
    data['runtime_state'] = data['runtime_state'].except(*SECRET_DATA_KEYS) if data['runtime_state'].is_a?(Hash)
    payload.merge('telegram_personal' => { 'data' => data })
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
    @webhook_data ||= raw_webhook_data
  end

  def raw_webhook_data
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
