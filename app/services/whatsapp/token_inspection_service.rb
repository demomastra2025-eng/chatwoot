class Whatsapp::TokenInspectionService
  REQUIRED_PERMISSIONS = %w[whatsapp_business_management whatsapp_business_messaging].freeze
  REAUTHORIZATION_STATUSES = %w[invalid permission_missing app_id_mismatch waba_access_missing phone_number_mismatch].freeze
  EXPIRING_SOON_STATUS = 'expiring'.freeze
  HEALTHY_STATUS = 'healthy'.freeze
  HEALTHY_UNVERIFIED_STATUS = 'healthy_unverified'.freeze
  INVALID_STATUS = 'invalid'.freeze
  PERMISSION_MISSING_STATUS = 'permission_missing'.freeze
  APP_ID_MISMATCH_STATUS = 'app_id_mismatch'.freeze
  WABA_ACCESS_MISSING_STATUS = 'waba_access_missing'.freeze
  PHONE_NUMBER_MISMATCH_STATUS = 'phone_number_mismatch'.freeze

  attr_reader :metadata

  def initialize(access_token:, waba_id:, phone_number_id: nil, api_client: nil)
    @access_token = access_token
    @waba_id = waba_id.to_s
    @phone_number_id = phone_number_id.presence&.to_s
    @api_client = api_client || Whatsapp::FacebookApiClient.new(access_token)
    @metadata = {}
    @status = nil
    @debug_token_failed = false
  end

  def perform
    validate_parameters!

    inspect_debug_token
    verify_waba_access unless invalid_status?
    finalize_metadata
  end

  def reauthorization_required?
    REAUTHORIZATION_STATUSES.include?(@metadata['status'])
  end

  private

  def validate_parameters!
    raise ArgumentError, 'Access token is required' if @access_token.blank?
    raise ArgumentError, 'WABA ID is required' if @waba_id.blank?
  end

  def inspect_debug_token
    unless app_credentials_configured?
      @debug_token_failed = true
      @metadata['debug_token'] = { 'available' => false, 'error' => 'WHATSAPP_APP_ID or WHATSAPP_APP_SECRET is not configured' }
      return
    end

    response = @api_client.debug_token(@access_token)
    data = response['data'].to_h
    @metadata.merge!(debug_metadata(data))

    mark_invalid('Token is not valid') if data.key?('is_valid') && !data['is_valid']
    mark_invalid('Token has expired') if token_expired?(data)
    inspect_app_id(data) unless invalid_status?
    inspect_required_permissions(data) unless invalid_status?
  rescue StandardError => e
    @debug_token_failed = true
    @metadata['debug_token'] = { 'available' => false, 'error' => safe_error_message(e) }
  end

  def verify_waba_access
    phone_number_ids = fetch_phone_number_ids

    @metadata['waba_access'] = true
    @metadata['phone_number_id'] = @phone_number_id if @phone_number_id.present?

    return if @phone_number_id.blank?

    @metadata['phone_number_access'] = phone_number_ids.include?(@phone_number_id)
    return if @metadata['phone_number_access']

    @metadata['available_phone_number_ids'] = phone_number_ids
    @status = PHONE_NUMBER_MISMATCH_STATUS
  rescue StandardError => e
    @metadata['waba_access'] = false
    @metadata['error'] = error_metadata(e)
    @status = oauth_token_error?(e) ? INVALID_STATUS : WABA_ACCESS_MISSING_STATUS
  end

  def fetch_phone_number_ids
    response = @api_client.fetch_phone_numbers(@waba_id)
    phone_number_ids = []

    loop do
      phone_number_ids.concat(Array(response['data']).pluck('id').map(&:to_s))
      break if @phone_number_id.present? && phone_number_ids.include?(@phone_number_id)

      after = next_phone_page_cursor(response)
      break if after.blank?

      response = @api_client.fetch_phone_numbers(@waba_id, after: after)
    end

    phone_number_ids.uniq
  end

  def next_phone_page_cursor(response)
    response.dig('paging', 'cursors', 'after') if response.dig('paging', 'next').present?
  end

  def finalize_metadata
    @metadata['checked_at'] = Time.current.iso8601
    @metadata['required_permissions'] ||= default_permission_metadata
    @metadata['status'] = @status || resolved_healthy_status
    @metadata
  end

  def debug_metadata(data)
    metadata = base_debug_metadata(data)
    apply_expiry_metadata(metadata, data)
    metadata
  end

  def base_debug_metadata(data)
    {
      'debug_token' => { 'available' => true },
      'token_type' => data['type'],
      'app_id' => data['app_id'],
      'application' => data['application'],
      'user_id' => data['user_id'],
      'is_valid' => data['is_valid'],
      'scopes' => Array(data['scopes']).map(&:to_s),
      'data_access_expires_at' => timestamp_metadata(data['data_access_expires_at']),
      'last_debug_at' => Time.current.iso8601,
      'granular_scopes' => token_granular_scope_summary(data)
    }.compact
  end

  def inspect_app_id(data)
    expected_app_id = GlobalConfigService.load('WHATSAPP_APP_ID', '').to_s
    token_app_id = data['app_id'].to_s
    return if expected_app_id.blank? || token_app_id.blank? || token_app_id == expected_app_id

    @metadata['expected_app_id'] = expected_app_id
    @metadata['app_id_matches_config'] = false
    @status = APP_ID_MISMATCH_STATUS
  end

  def apply_expiry_metadata(metadata, data)
    expires_at = data['expires_at'].to_i
    if expires_at.positive?
      metadata['expires_at'] = Time.at(expires_at).utc.iso8601
      metadata['expires_in_days'] = ((Time.at(expires_at).utc - Time.current) / 1.day).floor
      @status = EXPIRING_SOON_STATUS if Time.at(expires_at).utc > Time.current && metadata['expires_in_days'] <= expiry_warning_days
    elsif data.key?('expires_at')
      metadata['never_expires'] = true
    end
  end

  def inspect_required_permissions(data)
    permissions = REQUIRED_PERMISSIONS.index_with { |permission| permission_granted?(data, permission) }
    @metadata['required_permissions'] = permissions

    missing_permissions = permissions.reject { |_permission, granted| granted }.keys
    return if missing_permissions.empty?

    @metadata['missing_permissions'] = missing_permissions
    @status = PERMISSION_MISSING_STATUS
  end

  def permission_granted?(data, permission)
    return true if Array(data['scopes']).map(&:to_s).include?(permission)

    granular_scope = Array(data['granular_scopes']).find { |scope| scope['scope'].to_s == permission }
    return false if granular_scope.blank?

    target_ids = Array(granular_scope['target_ids']).map(&:to_s)
    target_ids.blank? || target_ids.include?(@waba_id)
  end

  def token_granular_scope_summary(data)
    Array(data['granular_scopes']).map do |scope|
      {
        'scope' => scope['scope'],
        'target_ids' => Array(scope['target_ids'])
      }.compact
    end
  end

  def token_expired?(data)
    expires_at = data['expires_at'].to_i
    expires_at.positive? && Time.at(expires_at).utc <= Time.current
  end

  def timestamp_metadata(value)
    timestamp = value.to_i
    return nil unless timestamp.positive?

    Time.at(timestamp).utc.iso8601
  end

  def resolved_healthy_status
    return EXPIRING_SOON_STATUS if @status == EXPIRING_SOON_STATUS
    return HEALTHY_UNVERIFIED_STATUS if @debug_token_failed

    HEALTHY_STATUS
  end

  def mark_invalid(message)
    @status = INVALID_STATUS
    @metadata['error'] ||= { 'message' => message }
  end

  def invalid_status?
    @status == INVALID_STATUS
  end

  def default_permission_metadata
    REQUIRED_PERMISSIONS.index_with { nil }
  end

  def oauth_token_error?(error)
    payload = error.respond_to?(:payload) ? error.payload : {}
    provider_error = Channel::Whatsapp.normalize_provider_error(payload)
    provider_error['code'].to_i == Channel::Whatsapp::AUTHORIZATION_ERROR_CODE ||
      provider_error['message'].to_s.match?(/access token|session has expired|validating access token/i)
  end

  def error_metadata(error)
    payload = error.respond_to?(:payload) ? error.payload : {}
    provider_error = Channel::Whatsapp.normalize_provider_error(payload)

    {
      'code' => provider_error['code'],
      'type' => provider_error['type'],
      'message' => provider_error['message'].presence || safe_error_message(error),
      'fbtrace_id' => provider_error['fbtrace_id']
    }.compact
  end

  def safe_error_message(error)
    error.message.to_s.gsub(@access_token.to_s, '[FILTERED]')
  end

  def app_credentials_configured?
    GlobalConfigService.load('WHATSAPP_APP_ID', '').present? &&
      GlobalConfigService.load('WHATSAPP_APP_SECRET', '').present?
  end

  def expiry_warning_days
    ENV.fetch('WHATSAPP_TOKEN_EXPIRY_WARNING_DAYS', 30).to_i
  end
end
