# frozen_string_literal: true

class Meta::AuthorizationHealthCheckService
  GRAPH_BASE_URI = 'https://graph.facebook.com'
  INSTAGRAM_GRAPH_BASE_URI = 'https://graph.instagram.com'
  REQUEST_TIMEOUT = 10

  Result = Struct.new(:status, :reason, :error, :metadata, keyword_init: true) do
    def healthy?
      status == :healthy
    end

    def transient?
      status == :transient_failure
    end

    def action_required?
      status == :action_required
    end

    def degraded?
      status == :degraded
    end
  end

  def initialize(channel)
    @channel = channel
  end

  def result
    @result ||= perform_check
  rescue StandardError => e
    Rails.logger.warn("[META AUTH HEALTH] #{@channel.class.name} #{@channel.id}: #{e.class}: #{safe_message(e.message)}")
    @result = transient_result('provider_request_failed', error: { 'type' => e.class.name, 'message' => safe_message(e.message) })
  end

  def healthy?
    result.healthy?
  end

  private

  def perform_check
    return action_required_result('channel_missing') if @channel.blank?

    case @channel
    when Channel::Instagram
      instagram_result
    when Channel::FacebookPage
      facebook_page_result
    when Channel::Whatsapp
      whatsapp_cloud_result
    else
      action_required_result('unsupported_channel')
    end
  end

  def instagram_result
    token = @channel[:access_token]
    return action_required_result('token_missing') if token.blank?
    return action_required_result('token_expired', metadata: expiry_metadata) if @channel.expires_at.present? && Time.current >= @channel.expires_at

    version = GlobalConfigService.load('INSTAGRAM_API_VERSION', 'v22.0')
    identity = graph_get(
      "#{INSTAGRAM_GRAPH_BASE_URI}/#{version}/me",
      query: { fields: 'user_id,username', access_token: token }.merge(appsecret_proof_query(token, 'INSTAGRAM_APP_SECRET')),
      expected_id: @channel.instagram_id,
      id_field: 'user_id'
    )
    return identity unless identity.healthy?

    subscription_result(
      "#{INSTAGRAM_GRAPH_BASE_URI}/#{version}/#{@channel.instagram_id}/subscribed_apps",
      query: { access_token: token }.merge(appsecret_proof_query(token, 'INSTAGRAM_APP_SECRET')),
      expected_app_id: GlobalConfigService.load('INSTAGRAM_APP_ID', nil),
      metadata: identity.metadata.merge(expiry_metadata)
    )
  end

  def facebook_page_result
    token = @channel.page_access_token
    page_id = @channel.page_id
    return action_required_result('token_missing') if token.blank?
    return action_required_result('asset_missing') if page_id.blank?

    version = GlobalConfigService.load('FACEBOOK_API_VERSION', 'v18.0')
    token_result = Meta::FacebookTokenHealthCheckService.new(@channel, version: version).result
    return token_result unless token_result.healthy?

    facebook_page_asset_result(token, page_id, version, token_result)
  end

  def facebook_page_asset_result(token, page_id, version, token_result)
    identity = graph_get(
      "#{GRAPH_BASE_URI}/#{version}/#{page_id}",
      query: { fields: 'id', access_token: token }.merge(appsecret_proof_query(token, 'FB_APP_SECRET')),
      expected_id: page_id
    )
    return identity unless identity.healthy?

    subscription_result(
      "#{GRAPH_BASE_URI}/#{version}/#{page_id}/subscribed_apps",
      query: { access_token: token }.merge(appsecret_proof_query(token, 'FB_APP_SECRET')),
      expected_app_id: token_result.metadata['app_id'],
      metadata: token_result.metadata.merge(identity.metadata)
    )
  end

  def whatsapp_cloud_result
    return action_required_result('unsupported_provider') unless @channel.provider == 'whatsapp_cloud'

    config = @channel.provider_config.to_h
    token = config['api_key']
    phone_number_id = config['phone_number_id']
    return action_required_result('token_missing') if token.blank?
    return action_required_result('asset_missing') if phone_number_id.blank?

    version = GlobalConfigService.load('WHATSAPP_API_VERSION', 'v22.0')
    graph_get(
      "#{GRAPH_BASE_URI}/#{version}/#{phone_number_id}",
      query: { fields: 'id', access_token: token }.merge(Whatsapp::FacebookApiClient.appsecret_proof_query(token).to_h),
      expected_id: phone_number_id
    )
  end

  def graph_get(url, query:, expected_id: nil, id_field: 'id')
    response = HTTParty.get(url, query: query, headers: { 'Accept' => 'application/json' }, timeout: REQUEST_TIMEOUT)
    return failed_response_result(response) unless response.respond_to?(:success?) && response.success?

    payload = parsed_response(response)
    actual_id = payload[id_field]
    return malformed_response_result if actual_id.blank?

    if expected_id.present? && actual_id.to_s != expected_id.to_s
      return action_required_result('asset_mismatch', metadata: { 'expected_id' => expected_id.to_s, 'actual_id' => actual_id.to_s })
    end

    healthy_result(metadata: { 'asset_id' => actual_id.to_s }.compact_blank)
  end

  def subscription_result(url, query:, expected_app_id:, metadata: {})
    return transient_result('app_configuration_missing', metadata: metadata) if expected_app_id.blank?

    response = HTTParty.get(url, query: query, headers: { 'Accept' => 'application/json' }, timeout: REQUEST_TIMEOUT)
    return failed_response_result(response) unless response.respond_to?(:success?) && response.success?

    data = parsed_response(response)['data']
    return malformed_response_result(metadata: metadata) unless data.is_a?(Array)

    subscribed = data.any? { |entry| entry.to_h['id'].to_s == expected_app_id.to_s }

    return degraded_result('subscription_missing', metadata: metadata.merge('expected_app_id' => expected_app_id.to_s)) unless subscribed

    healthy_result(metadata: metadata.merge('subscription_present' => true))
  end

  def failed_response_result(response)
    classification = Meta::AuthorizationErrorClassifier.classify(response, http_status: response.respond_to?(:code) ? response.code : nil)
    reason = classification.kind == :permission_missing ? 'permission_missing' : 'provider_authorization_failed'

    if classification.action_required?
      action_required_result(reason, error: sanitized_error(classification.error))
    else
      transient_result('provider_request_failed', error: sanitized_error(classification.error))
    end
  end

  def healthy_result(metadata: {})
    Result.new(status: :healthy, reason: 'healthy', metadata: metadata.compact_blank)
  end

  def degraded_result(reason, metadata: {})
    Result.new(status: :degraded, reason: reason, metadata: metadata.compact_blank)
  end

  def transient_result(reason, error: nil, metadata: {})
    Result.new(status: :transient_failure, reason: reason, error: error, metadata: metadata.compact_blank)
  end

  def malformed_response_result(metadata: {})
    transient_result('provider_response_invalid', metadata: metadata)
  end

  def action_required_result(reason, error: nil, metadata: {})
    Result.new(status: :action_required, reason: reason, error: error, metadata: metadata.compact_blank)
  end

  def parsed_response(response)
    parsed = response.parsed_response
    return parsed.to_h.deep_stringify_keys if parsed.respond_to?(:to_h)

    JSON.parse(response.body.to_s)
  rescue JSON::ParserError
    {}
  end

  def appsecret_proof_query(token, secret_key)
    app_secret = GlobalConfigService.load(secret_key, nil)
    return {} if token.blank? || app_secret.blank?

    { appsecret_proof: OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha256'), app_secret, token) }
  end

  def expiry_metadata
    { 'expires_at' => @channel.expires_at&.utc&.iso8601 }.compact
  end

  def sanitized_error(error)
    error.to_h.deep_stringify_keys.merge('message' => safe_message(error.to_h['message']))
  end

  def safe_message(message)
    secrets = Meta::CredentialDataSanitizer.channel_secrets(@channel)
    Meta::CredentialDataSanitizer.sanitize(message.to_s.first(500), secrets: secrets)
  end
end
