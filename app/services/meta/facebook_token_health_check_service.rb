# frozen_string_literal: true

class Meta::FacebookTokenHealthCheckService
  GRAPH_BASE_URI = 'https://graph.facebook.com'
  REQUEST_TIMEOUT = 10
  REQUIRED_SCOPES = %w[pages_manage_metadata pages_messaging].freeze
  INVALID_TIMESTAMP = Object.new.freeze

  def initialize(channel, version:)
    @channel = channel
    @version = version
  end

  def result
    return transient_result('app_configuration_missing') if app_id.blank? || app_secret.blank?

    response = HTTParty.get(
      "#{GRAPH_BASE_URI}/#{@version}/debug_token",
      query: { input_token: @channel.page_access_token, access_token: "#{app_id}|#{app_secret}" },
      headers: { 'Accept' => 'application/json' },
      timeout: REQUEST_TIMEOUT
    )
    return failed_response_result(response) unless response.respond_to?(:success?) && response.success?

    validate_data(parsed_data(response))
  rescue StandardError => e
    transient_result('provider_request_failed', error: { 'type' => e.class.name, 'message' => safe_message(e.message) })
  end

  private

  def validate_data(data)
    return transient_result('provider_response_invalid') unless data.is_a?(Hash)
    return action_required_result('provider_authorization_failed') unless data['is_valid'] == true
    return action_required_result('app_mismatch') unless data['app_id'].to_s == app_id.to_s

    expiry_result(data) || permission_result(data) || healthy_result(data)
  end

  def expiry_result(data)
    expires_at = timestamp_time(data['expires_at'])
    data_expires_at = timestamp_time(data['data_access_expires_at'])
    return transient_result('provider_response_invalid') if [expires_at, data_expires_at].include?(INVALID_TIMESTAMP)
    return action_required_result('token_expired', metadata: { 'expires_at' => expires_at.iso8601 }) if expires_at && expires_at <= Time.current
    return unless data_expires_at && data_expires_at <= Time.current

    action_required_result('data_access_expired', metadata: { 'data_access_expires_at' => data_expires_at.iso8601 })
  end

  def permission_result(data)
    scopes = Array(data['scopes']).map(&:to_s)
    return transient_result('provider_response_invalid') if scopes.empty?

    missing_scopes = REQUIRED_SCOPES - scopes
    return if missing_scopes.empty?

    action_required_result('permission_missing', metadata: { 'missing_scopes' => missing_scopes })
  end

  def healthy_result(data)
    build_result(
      :healthy,
      'healthy',
      metadata: {
        'app_id' => app_id.to_s,
        'expires_at' => timestamp_iso8601(data['expires_at']),
        'data_access_expires_at' => timestamp_iso8601(data['data_access_expires_at']),
        'scopes_verified' => REQUIRED_SCOPES
      }.compact_blank
    )
  end

  def failed_response_result(response)
    classification = Meta::AuthorizationErrorClassifier.classify(
      response,
      http_status: response.respond_to?(:code) ? response.code : nil
    )
    reason = classification.kind == :permission_missing ? 'permission_missing' : 'provider_authorization_failed'
    status = classification.action_required? ? :action_required : :transient_failure
    build_result(status, classification.action_required? ? reason : 'provider_request_failed', error: classification.error)
  end

  def parsed_data(response)
    parsed = response.parsed_response
    payload = parsed.respond_to?(:to_h) ? parsed.to_h.deep_stringify_keys : JSON.parse(response.body.to_s)
    payload['data']
  rescue JSON::ParserError
    nil
  end

  def build_result(status, reason, error: nil, metadata: {})
    Meta::AuthorizationHealthCheckService::Result.new(
      status: status,
      reason: reason,
      error: error,
      metadata: metadata
    )
  end

  def transient_result(reason, error: nil, metadata: {})
    build_result(:transient_failure, reason, error: error, metadata: metadata)
  end

  def action_required_result(reason, error: nil, metadata: {})
    build_result(:action_required, reason, error: error, metadata: metadata)
  end

  def timestamp_time(value)
    return if value.nil? || value.to_s == '0'

    timestamp = positive_timestamp(value)
    timestamp ? Time.zone.at(timestamp) : INVALID_TIMESTAMP
  end

  def positive_timestamp(value)
    return value if value.is_a?(Integer) && value.positive?
    return value.to_i if value.is_a?(String) && value.match?(/\A[1-9]\d*\z/)
  end

  def timestamp_iso8601(value)
    timestamp_time(value)&.utc&.iso8601
  end

  def app_id
    @app_id ||= GlobalConfigService.load('FB_APP_ID', nil)
  end

  def app_secret
    @app_secret ||= GlobalConfigService.load('FB_APP_SECRET', nil)
  end

  def safe_message(message)
    secrets = Meta::CredentialDataSanitizer.channel_secrets(@channel)
    Meta::CredentialDataSanitizer.sanitize(message.to_s.first(500), secrets: secrets)
  end
end
