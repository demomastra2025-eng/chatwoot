# frozen_string_literal: true

class Whatsapp::Flows::ManagementService # rubocop:disable Metrics/ClassLength
  SUPPORTED_FLOW_CATEGORIES = %w[
    SIGN_UP SIGN_IN APPOINTMENT_BOOKING LEAD_GENERATION
    CONTACT_US CUSTOMER_SUPPORT SURVEY OTHER
  ].freeze
  FLOW_ID_FORMAT = /\A[A-Za-z0-9_-]{1,64}\z/

  pattr_initialize [:whatsapp_channel!]

  def ensure_local_credentials!(rotate_keys: false)
    update_flows_config! do |flows_cfg|
      assign_keypair_credentials!(flows_cfg, rotate_keys: rotate_keys) if keypair_missing_or_rotating?(flows_cfg, rotate_keys)
      flows_cfg['endpoint_secret'] = Whatsapp::Flows::TokenService.generate_endpoint_secret if flows_cfg['endpoint_secret'].blank?
      flows_cfg['encryption_status'] ||= 'pending_upload'
    end
  end

  def endpoint_uri
    flows_cfg = ensure_local_credentials!
    token = Whatsapp::Flows::TokenService.build_endpoint_token(whatsapp_channel, flows_cfg['endpoint_secret'])
    "#{validated_base_url!}/webhooks/whatsapp/flows/#{token}"
  end

  def setup_encryption!(rotate_keys: false)
    flows_cfg = ensure_local_credentials!(rotate_keys: rotate_keys)
    response = provider_service.upload_business_public_key(flows_cfg['public_key_pem'])

    unless response.success?
      update_flows_config! { |cfg| cfg['encryption_status'] = 'error' }
      return provider_failure_result(response, default_message: 'Failed to upload WhatsApp Flows public key')
    end

    mark_encryption_configured!
    { success: true, whatsapp_flows: public_flows_config }
  rescue ArgumentError => e
    failure_result(sanitized_data(e.message))
  rescue StandardError => e
    log_error('setup_encryption', e)
    internal_failure_result
  end

  def sync_flows!
    result = provider_service.fetch_all_flows
    return provider_failure_result(result[:response], default_message: 'Failed to fetch WhatsApp Flows') unless result[:success]

    merge_remote_flows!(result[:data])
    { success: true, whatsapp_flows: public_flows_config }
  rescue StandardError => e
    log_error('sync_flows', e)
    internal_failure_result
  end

  def provision_booking_flow!(raw_params = {})
    params = raw_params.to_h.with_indifferent_access
    encryption_result = ensure_encryption_uploaded!
    return encryption_result unless encryption_result[:success]

    return create_and_upload_flow(intake_flow_creation_options(params)) if params[:flow_type].to_s == 'clinic_intake'

    locale = Whatsapp::Flows::BookingFlowCopy.normalize_locale(params[:locale], account: whatsapp_channel.account)
    create_and_upload_flow(booking_flow_creation_options(locale, params))
  rescue ArgumentError => e
    failure_result(sanitized_data(e.message))
  rescue StandardError => e
    log_error('provision_booking_flow', e)
    internal_failure_result
  end

  def create_flow!(raw_params = {})
    params = raw_params.to_h.with_indifferent_access
    options = custom_flow_creation_options(params)
    if options[:use_endpoint]
      encryption_result = ensure_encryption_uploaded!
      return encryption_result unless encryption_result[:success]
    end

    create_and_upload_flow(options)
  rescue ArgumentError => e
    failure_result(sanitized_data(e.message))
  rescue StandardError => e
    log_error('create_flow', e)
    internal_failure_result
  end

  def publish_flow!(raw_flow_id)
    flow_id = validate_flow_id!(raw_flow_id)
    response = provider_service.publish_flow(flow_id)
    return provider_failure_result(response, default_message: 'Failed to publish WhatsApp Flow') unless response.success?

    update_cached_flow_status!(flow_id, 'PUBLISHED', clear_publish_error: true)
    { success: true, whatsapp_flows: public_flows_config }
  rescue ArgumentError => e
    failure_result(sanitized_data(e.message))
  rescue StandardError => e
    log_error('publish_flow', e)
    internal_failure_result
  end

  def remove_flow!(raw_flow_id)
    flow_id = validate_flow_id!(raw_flow_id)
    cached = find_cached_flow(flow_id)
    return handle_non_draft_removal!(flow_id, cached['status'].to_s.upcase) if cached.present? && cached['status'].to_s.upcase != 'DRAFT'

    delete_or_fallback_deprecate!(flow_id, uncached: cached.nil?)
  rescue ArgumentError => e
    failure_result(sanitized_data(e.message))
  rescue StandardError => e
    log_error('remove_flow', e)
    internal_failure_result
  end

  def public_flows_config
    Whatsapp::ProviderConfigPresenter.new(whatsapp_channel).perform['whatsapp_flows'] || {}
  end

  private

  def provider_service
    whatsapp_channel.provider_service
  end

  def current_flows_config
    (whatsapp_channel.provider_config.to_h['whatsapp_flows'] || {}).deep_dup
  end

  def update_flows_config!
    result_cfg = nil
    whatsapp_channel.with_lock do
      fresh_provider_cfg = whatsapp_channel.provider_config.to_h.deep_dup
      flows_cfg = (fresh_provider_cfg['whatsapp_flows'] || {}).deep_dup
      yield(flows_cfg)
      fresh_provider_cfg['whatsapp_flows'] = flows_cfg
      whatsapp_channel.update!(provider_config: fresh_provider_cfg)
      result_cfg = flows_cfg
    end
    result_cfg
  end

  def mark_encryption_configured!
    update_flows_config! do |cfg|
      cfg['encryption_status'] = 'configured'
      cfg['public_key_uploaded_at'] = Time.current.iso8601
    end
  end

  def keypair_missing_or_rotating?(flows_cfg, rotate_keys)
    return true if rotate_keys || flows_cfg['encrypted_private_key'].blank? || flows_cfg['public_key_pem'].blank?

    !decryptable_private_key?(flows_cfg['encrypted_private_key'])
  end

  def decryptable_private_key?(encrypted_pem)
    Whatsapp::Flows::CryptoService.decrypt_private_key(encrypted_pem).present?
  rescue Whatsapp::Flows::CryptoService::DecryptionError
    false
  end

  def assign_keypair_credentials!(flows_cfg, rotate_keys:)
    keypair = Whatsapp::Flows::CryptoService.generate_keypair
    flows_cfg['public_key_pem'] = keypair[:public_key_pem]
    flows_cfg['encrypted_private_key'] = Whatsapp::Flows::CryptoService.encrypt_private_key(keypair[:private_key_pem])
    flows_cfg['encryption_status'] = 'pending_upload' if rotate_keys || flows_cfg['encryption_status'] == 'configured'
  end

  def merge_remote_flows!(remote_items)
    update_flows_config! do |flows_cfg|
      existing_by_id = Array(flows_cfg['flows']).index_by { |item| item['id'].to_s }
      flows_cfg['flows'] = remote_items.map { |remote| normalize_flow_record(remote, existing_by_id[remote['id'].to_s]) }
      flows_cfg['flows_synced_at'] = Time.current.iso8601
      reconcile_booking_flow_id!(flows_cfg)
    end
  end

  def booking_flow_creation_options(locale, params)
    preset = Whatsapp::Flows::ClinicProfile.detect_preset(whatsapp_channel.account, params[:clinic_preset])
    {
      name: params[:name].to_s.strip.presence || default_booking_flow_name(locale, preset),
      categories: ['APPOINTMENT_BOOKING'],
      flow_json: build_booking_flow_json(locale, params, preset),
      use_endpoint: true,
      publish: cast_boolean(params[:publish]),
      local_meta: { 'kind' => 'booking', 'locale' => locale, 'clinic_preset' => preset },
      set_as_booking: true
    }
  end

  def intake_flow_creation_options(params)
    preset = Whatsapp::Flows::ClinicProfile.detect_preset(whatsapp_channel.account, params[:clinic_preset])
    cfg = Whatsapp::Flows::ClinicProfile.config_for(account: whatsapp_channel.account, preset: preset)
    default_name = "#{cfg[:intake_flow_default_name]} - #{whatsapp_channel.inbox&.id || whatsapp_channel.id}"
    {
      name: params[:name].to_s.strip.presence || default_name,
      categories: ['CUSTOMER_SUPPORT'],
      flow_json: Whatsapp::Flows::ClinicIntakeFlowSchemaBuilder.new(account: whatsapp_channel.account, preset: preset).to_json,
      use_endpoint: false,
      publish: cast_boolean(params[:publish]),
      local_meta: { 'kind' => 'clinic_intake', 'clinic_preset' => preset },
      set_as_booking: false
    }
  end

  def custom_flow_creation_options(params)
    name = params[:name].to_s.strip
    raise ArgumentError, 'Flow name is required' if name.blank?

    {
      name: name,
      categories: normalize_categories(params[:categories]),
      flow_json: normalize_optional_flow_json(params[:flow_json]),
      use_endpoint: params.key?(:use_endpoint) ? cast_boolean(params[:use_endpoint]) : false,
      publish: cast_boolean(params[:publish]),
      local_meta: { 'kind' => params[:kind].to_s.presence || 'custom' },
      set_as_booking: false
    }
  end

  def cast_boolean(value)
    ActiveModel::Type::Boolean.new.cast(value)
  end

  def ensure_encryption_uploaded!
    cfg = current_flows_config
    ready = cfg['encryption_status'] == 'configured' && decryptable_private_key?(cfg['encrypted_private_key'])
    return { success: true } if ready

    setup_encryption!
  end

  def create_and_upload_flow(options)
    target_endpoint = options[:use_endpoint] ? endpoint_uri : nil
    create_response = provider_service.create_flow(name: options[:name], categories: options[:categories], endpoint_uri: target_endpoint)
    return provider_failure_result(create_response, default_message: 'Failed to create WhatsApp Flow') unless create_response.success?

    flow_id = create_response.parsed_response.to_h['id'].to_s
    raise ArgumentError, 'Meta did not return a Flow ID' if flow_id.blank?

    finalize_created_flow(flow_id, options, target_endpoint)
  end

  def finalize_created_flow(flow_id, options, target_endpoint)
    validation_errors = upload_flow_asset_if_present(flow_id, options[:flow_json])
    return validation_errors if validation_errors.is_a?(Hash) && validation_errors[:success] == false

    pub_outcome = maybe_publish_created_flow(flow_id, options[:publish], validation_errors)
    upsert_created_flow_cache!(flow_id, pub_outcome, target_endpoint, validation_errors, options)

    {
      success: true,
      flow_id: flow_id,
      status: pub_outcome[:status],
      publish_error: pub_outcome[:publish_error],
      validation_errors: validation_errors,
      whatsapp_flows: public_flows_config
    }.compact
  end

  def upload_flow_asset_if_present(flow_id, flow_json)
    return [] if flow_json.blank?

    asset_response = provider_service.upload_flow_json(flow_id, flow_json)
    return provider_failure_result(asset_response, default_message: 'Flow was created, but uploading flow.json failed') unless asset_response.success?

    Array(asset_response.parsed_response.to_h['validation_errors'])
  end

  def maybe_publish_created_flow(flow_id, publish, validation_errors)
    return { status: 'DRAFT', publish_error: nil } unless publish
    return { status: 'DRAFT', publish_error: 'Flow has schema validation errors and remains in DRAFT' } if validation_errors.any?

    pub_response = provider_service.publish_flow(flow_id)
    return { status: 'PUBLISHED', publish_error: nil } if pub_response.success?

    err_msg = sanitized_data(parse_provider_error(pub_response&.body)[:user_message].presence || 'Failed to publish WhatsApp Flow')
    log_publish_warning(flow_id, err_msg)
    { status: 'DRAFT', publish_error: err_msg }
  end

  def upsert_created_flow_cache!(flow_id, pub_outcome, target_endpoint, validation_errors, options)
    record = build_cached_flow_record(flow_id, pub_outcome, target_endpoint, validation_errors, options)
    update_flows_config! do |flows_cfg|
      flows = Array(flows_cfg['flows']).reject { |item| item['id'].to_s == flow_id }
      flows_cfg['flows'] = [record, *flows]
      assign_booking_flow_defaults!(flows_cfg, flow_id, options[:local_meta]) if options[:set_as_booking]
      flows_cfg['flows_synced_at'] = Time.current.iso8601
    end
  end

  def build_cached_flow_record(flow_id, pub_outcome, target_endpoint, validation_errors, options)
    versions = extract_flow_json_versions(options[:flow_json], target_endpoint)
    {
      'id' => flow_id,
      'name' => options[:name],
      'status' => pub_outcome[:status],
      'categories' => options[:categories],
      'json_version' => versions[:json_version],
      'data_api_version' => versions[:data_api_version],
      'validation_errors' => validation_errors,
      'last_publish_error' => pub_outcome[:publish_error]
    }.merge(options[:local_meta]).compact
  end

  def extract_flow_json_versions(raw_flow_json, target_endpoint)
    parsed = raw_flow_json.present? ? JSON.parse(raw_flow_json.to_s) : {}
    default_json_ver = raw_flow_json.present? ? Whatsapp::Flows::BookingFlowSchemaBuilder::FLOW_JSON_VERSION : nil
    default_api_ver = target_endpoint.present? ? Whatsapp::Flows::BookingFlowSchemaBuilder::DATA_API_VERSION : nil
    {
      json_version: parsed['version'].presence || default_json_ver,
      data_api_version: parsed['data_api_version'].presence || default_api_ver
    }
  rescue JSON::ParserError
    { json_version: nil, data_api_version: nil }
  end

  def assign_booking_flow_defaults!(flows_cfg, flow_id, local_meta)
    flows_cfg['booking_flow_id'] = flow_id
    flows_cfg['booking_locale'] = local_meta['locale'] if local_meta['locale'].present?
    flows_cfg['clinic_preset'] = local_meta['clinic_preset'] if local_meta['clinic_preset'].present?
  end

  def handle_non_draft_removal!(flow_id, cached_status)
    return { success: true, action: 'deprecated', whatsapp_flows: public_flows_config } if cached_status == 'DEPRECATED'

    deprecate_published_flow!(flow_id)
  end

  def delete_or_fallback_deprecate!(flow_id, uncached:)
    response = provider_service.delete_flow(flow_id)
    if response.success?
      remove_cached_flow!(flow_id)
      return { success: true, action: 'deleted', whatsapp_flows: public_flows_config }
    end

    return deprecate_published_flow!(flow_id) if uncached

    provider_failure_result(response, default_message: 'Failed to delete WhatsApp Flow')
  end

  def deprecate_published_flow!(flow_id)
    response = provider_service.deprecate_flow(flow_id)
    return provider_failure_result(response, default_message: 'Failed to deprecate published WhatsApp Flow') unless response.success?

    update_cached_flow_status!(flow_id, 'DEPRECATED')
    { success: true, action: 'deprecated', whatsapp_flows: public_flows_config }
  end

  def update_cached_flow_status!(flow_id, new_status, clear_publish_error: false)
    update_flows_config! do |flows_cfg|
      flows_cfg['flows'] = Array(flows_cfg['flows']).map do |item|
        next item unless item['id'].to_s == flow_id

        updated = item.merge('status' => new_status)
        updated.delete('last_publish_error') if clear_publish_error
        updated
      end
      flows_cfg['booking_flow_id'] = nil if new_status == 'DEPRECATED' && flows_cfg['booking_flow_id'].to_s == flow_id
    end
  end

  def remove_cached_flow!(flow_id)
    update_flows_config! do |flows_cfg|
      flows_cfg['flows'] = Array(flows_cfg['flows']).reject { |item| item['id'].to_s == flow_id }
      flows_cfg['booking_flow_id'] = nil if flows_cfg['booking_flow_id'].to_s == flow_id
    end
  end

  def find_cached_flow(flow_id)
    Array(current_flows_config['flows']).find { |item| item['id'].to_s == flow_id }
  end

  def normalize_flow_record(remote, existing)
    data = remote.to_h
    existing_data = existing.to_h
    categories = Array(data['categories']).map(&:to_s)
    inferred_kind = existing_data['kind'].presence || (categories.include?('APPOINTMENT_BOOKING') ? 'booking' : 'custom')

    {
      'id' => data['id'].to_s, 'name' => data['name'].to_s,
      'status' => data['status'].to_s.upcase.presence || 'DRAFT',
      'categories' => categories, 'json_version' => data['json_version'],
      'data_api_version' => data['data_api_version'],
      'validation_errors' => Array(data['validation_errors']),
      'kind' => inferred_kind, 'locale' => existing_data['locale']
    }.compact
  end

  def reconcile_booking_flow_id!(flows_cfg)
    flows = Array(flows_cfg['flows'])
    return if active_booking_flow_selected?(flows, flows_cfg['booking_flow_id'].to_s)

    booking_flows = flows.select { |item| active_booking_flow?(item) }
    preferred = booking_flows.find { |item| item['status'] == 'PUBLISHED' } || booking_flows.first
    flows_cfg['booking_flow_id'] = preferred&.[]('id')
  end

  def active_booking_flow_selected?(flows, current_id)
    current_id.present? && flows.any? { |item| item['id'].to_s == current_id && item['status'] != 'DEPRECATED' }
  end

  def active_booking_flow?(flow_item)
    flow_item['kind'] == 'booking' && flow_item['status'] != 'DEPRECATED'
  end

  def default_booking_flow_name(locale, preset = nil)
    cfg = Whatsapp::Flows::ClinicProfile.config_for(account: whatsapp_channel.account, preset: preset)
    copy = Whatsapp::Flows::BookingFlowCopy.for_locale(locale, account: whatsapp_channel.account)
    base_title = cfg[:flow_default_name].presence || copy[:flow_default_name]
    "#{base_title} (#{locale.upcase}) - #{whatsapp_channel.inbox&.id || whatsapp_channel.id}"
  end

  def build_booking_flow_json(locale, params, preset = nil)
    Whatsapp::Flows::BookingFlowSchemaBuilder.new(
      locale: locale,
      account: whatsapp_channel.account,
      specialist_label: params[:specialist_label],
      service_label: params[:service_label],
      confirm_cta: params[:confirm_cta],
      clinic_preset: preset
    ).to_json
  end

  def normalize_categories(raw_categories)
    list = Array(raw_categories).map { |cat| cat.to_s.strip.upcase }.compact_blank
    list = ['OTHER'] if list.empty?
    invalid = list - SUPPORTED_FLOW_CATEGORIES
    raise ArgumentError, "Unsupported Flow categories: #{invalid.join(', ')}" if invalid.any?

    list.uniq
  end

  def normalize_optional_flow_json(raw_json)
    return nil if raw_json.blank?
    return raw_json.to_json if raw_json.is_a?(Hash)

    parsed = JSON.parse(raw_json.to_s)
    raise ArgumentError, 'flow_json must be a JSON object' unless parsed.is_a?(Hash)

    JSON.generate(parsed)
  rescue JSON::ParserError => e
    raise ArgumentError, "flow_json is not valid JSON: #{e.message}"
  end

  def validate_flow_id!(raw_flow_id)
    flow_id = raw_flow_id.to_s.strip
    raise ArgumentError, 'Invalid WhatsApp Flow ID' unless flow_id.match?(FLOW_ID_FORMAT)

    flow_id
  end

  def validated_base_url!
    raw_url = ENV.fetch('WHATSAPP_FLOWS_ENDPOINT_BASE_URL', nil).presence || ENV.fetch('FRONTEND_URL', '').to_s.strip
    uri = URI.parse(raw_url.chomp('/'))
    valid_scheme = Rails.env.production? ? uri.is_a?(URI::HTTPS) : (uri.is_a?(URI::HTTPS) || uri.is_a?(URI::HTTP))
    raise ArgumentError, 'FRONTEND_URL must be a valid HTTPS URL for WhatsApp Flows' unless valid_scheme && uri.host.present?

    uri.to_s.chomp('/')
  rescue URI::InvalidURIError
    raise ArgumentError, 'FRONTEND_URL must be a valid HTTPS URL for WhatsApp Flows'
  end

  def provider_failure_result(response, default_message:)
    parsed_error = parse_provider_error(response&.body)
    failure_result(
      sanitized_data(parsed_error[:user_message].presence || default_message),
      details: sanitized_data(parsed_error[:details])
    )
  end

  def parse_provider_error(response_body)
    return { user_message: nil, details: nil } if response_body.blank?

    json = JSON.parse(response_body.to_s)
    err = json['error'] || {}
    {
      user_message: err['error_user_msg'] || err['message'],
      details: { code: err['code'], subcode: err['error_subcode'], type: err['type'], title: err['error_user_title'] }.compact
    }
  rescue JSON::ParserError
    { user_message: nil, details: nil }
  end

  def failure_result(error, details: nil) = { success: false, error: error, details: details }.compact
  def internal_failure_result = failure_result('WhatsApp Flows operation failed. Please try again.')

  def sanitized_data(data)
    Meta::CredentialDataSanitizer.sanitize(data, secrets: Meta::CredentialDataSanitizer.channel_secrets(whatsapp_channel))
  end

  def log_publish_warning(flow_id, err_msg)
    Rails.logger.warn(
      "[WHATSAPP FLOWS MANAGEMENT] publish_after_create failed channel=#{whatsapp_channel.id} flow=#{flow_id}: #{err_msg}"
    )
  end

  def log_error(operation, error)
    Rails.logger.error(
      "[WHATSAPP FLOWS MANAGEMENT] #{operation} failed channel=#{whatsapp_channel.id}: #{error.class}: #{sanitized_data(error.message)}"
    )
  end
end
