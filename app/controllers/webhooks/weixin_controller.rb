class Webhooks::WeixinController < ActionController::API
  GATEWAY_ISSUER = 'onelink-weixin-personal-gateway'.freeze
  WEBHOOK_TOKEN_CACHE_TTL = 5.minutes
  WEBHOOK_TOKEN_EXPIRY_LEEWAY = 30

  before_action :set_channel
  before_action :verify_signature!

  def process_payload
    payload = request_payload.deep_stringify_keys
    return render_unauthorized unless reserve_webhook_jti!

    if runtime_update_payload?(payload)
      Weixin::IncomingEventService.new(channel: @channel, payload: payload.deep_symbolize_keys).perform
    else
      persist_context_token!(payload)
      Channels::Weixin::ProcessWebhookEventJob.perform_later(@channel.id, sanitized_job_payload(payload))
    end

    head :ok
  rescue StandardError => e
    release_webhook_jti!
    Rails.logger.error("[WEIXIN] Webhook processing failed: #{e.message}")
    render json: { error: e.message }, status: error_status_for(e)
  end

  private

  def set_channel
    @channel = Channel::Weixin.find_by!(webhook_identifier: params[:webhook_identifier])
  end

  def verify_signature!
    token = request.headers['Authorization'].to_s.remove(/\ABearer\s+/)
    return render_unauthorized if token.blank?

    payload = JWT.decode(
      token,
      @channel.webhook_secret,
      true,
      algorithm: 'HS256',
      leeway: WEBHOOK_TOKEN_EXPIRY_LEEWAY
    ).first

    return render_unauthorized unless valid_token_payload?(payload)

    @webhook_jti = payload['jti']
  rescue JWT::DecodeError, JWT::VerificationError
    render_unauthorized
  end

  def valid_token_payload?(payload)
    payload['iss'] == GATEWAY_ISSUER &&
      payload['channel_id'].to_i == @channel.id &&
      payload['jti'].present? &&
      valid_body_hash?(payload['body_sha256'])
  end

  def valid_body_hash?(provided_hash)
    expected_hash = Digest::SHA256.hexdigest(request.raw_post)
    provided_hash = provided_hash.to_s
    return false unless provided_hash.bytesize == expected_hash.bytesize

    ActiveSupport::SecurityUtils.secure_compare(provided_hash, expected_hash)
  end

  def reserve_webhook_jti!
    Rails.cache.write(webhook_jti_cache_key, true, expires_in: WEBHOOK_TOKEN_CACHE_TTL, unless_exist: true)
  end

  def release_webhook_jti!
    return if @webhook_jti.blank?

    Rails.cache.delete(webhook_jti_cache_key)
  end

  def webhook_jti_cache_key
    "weixin:webhook:jti:#{@channel.id}:#{@webhook_jti}"
  end

  def render_unauthorized
    render json: { error: 'Unauthorized' }, status: :unauthorized
  end

  def request_payload
    {
      event: params[:event],
      weixin: {
        data: webhook_data
      }
    }
  end

  def webhook_data
    raw_data = params[:data]
    return raw_data.to_unsafe_h.deep_symbolize_keys if raw_data.respond_to?(:to_unsafe_h)
    return raw_data.deep_symbolize_keys if raw_data.is_a?(Hash)

    params.to_unsafe_hash
          .except('controller', 'action', 'webhook_identifier', 'event', 'weixin')
          .deep_symbolize_keys
  end

  def runtime_update_payload?(payload)
    payload['event'].to_s == 'runtime.updated'
  end

  def persist_context_token!(payload)
    data = payload.dig('weixin', 'data') || {}
    context_token = data['context_token'].presence
    return if context_token.blank?

    peer_id = data['chat_id'].presence || data['sender_id'].presence || data['peer_user_id'].presence || data['from_user_id'].presence
    @channel.remember_context_token!(peer_id, context_token)
  end

  def sanitized_job_payload(payload)
    deep_sanitize_sensitive_payload(payload)
  end

  def deep_sanitize_sensitive_payload(value)
    case value
    when Hash
      value.each_with_object({}) do |(key, child), sanitized|
        next if sensitive_payload_key?(key)

        sanitized[key] = deep_sanitize_sensitive_payload(child)
      end
    when Array
      value.map { |child| deep_sanitize_sensitive_payload(child) }
    else
      value
    end
  end

  def sensitive_payload_key?(key)
    %w[ilink_token context_token context_tokens webhook_secret].include?(key.to_s)
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
