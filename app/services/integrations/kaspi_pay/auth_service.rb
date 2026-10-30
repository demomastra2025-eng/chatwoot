# frozen_string_literal: true

class Integrations::KaspiPay::AuthService
  APP_ID = 'kaspi_pay'
  VERSION_RESOLVER = Integrations::KaspiPay::AppVersionResolver
  DISCONNECTED_PAYLOAD = {
    connected: false, hook_id: nil, session_status: 'disconnected', organization_name: nil,
    organization_bin: nil, organization_id: nil, profile_id: nil, organizations: [],
    cashier_phone_masked: nil, auto_send_link_to_chat: true, app_version: nil,
    app_build: nil, connected_at: nil, last_verified_at: nil, last_error: nil
  }.freeze

  def initialize(account:)
    @account = account
    @pending_store = Integrations::KaspiPay::PendingAuthStore.new(account_id: account.id)
  end

  def hook = @hook ||= @account.hooks.find_by(app_id: APP_ID)

  def status_payload(verify_live: false)
    return DISCONNECTED_PAYLOAD.dup if hook.blank? || hook.disabled?

    check_session! if verify_live
    build_connected_status(hook.reload)
  end

  def send_otp!(raw_phone:, app_version: nil, app_build: nil)
    phone_10 = Integrations::KaspiPay::PhoneNormalizer.to_kaspi_10_digits!(raw_phone)
    device = resolve_device_identity
    explicit_overrides = { version: app_version.presence, build: app_build.presence }.compact
    otp_res, effective_overrides = send_otp_with_version_retry(device, phone_10, explicit_overrides)

    save_pending_otp!(otp_res, device: device, phone_10: phone_10, app_overrides: effective_overrides, explicit_overrides: explicit_overrides)
    masked = Integrations::KaspiPay::PhoneNormalizer.mask(phone_10)
    { process_id: otp_res[:process_id], phone_masked: masked, description: otp_res[:desc].presence || "SMS-код отправлен на #{masked}" }
  end

  def verify_otp!(process_id:, otp:)
    raise Integrations::KaspiPay::ApiClient::ApiError.new('Укажите SMS-код подтверждения', code: 'BlankOtp') if otp.to_s.strip.blank?

    pending = @pending_store.fetch!(process_id)
    finish_res = complete_otp_verification!(process_id, otp, pending)
    persist_connected_hook!(pending, finish_res)
    @pending_store.delete!(process_id)
    status_payload
  end

  def check_session!
    return DISCONNECTED_PAYLOAD.dup if hook.blank? || hook.disabled?

    res = build_authenticated_client!(hook).check_session
    apply_session_check_result!(hook, res)
    res
  end

  def mark_session_evicted!(error_message)
    return if hook.blank?

    msg = error_message.presence || 'Сессия кассира Kaspi Pay вытеснена. Войдите повторно по SMS.'
    hook.update!(settings: (hook.settings || {}).merge('session_status' => 'reauth_required', 'last_error' => msg))
  end

  def update_settings!(params)
    raise ActiveRecord::RecordNotFound, 'Kaspi Pay не подключён' if hook.blank?

    settings = (hook.settings || {}).dup
    apply_boolean_setting!(settings, params)
    apply_profile_setting!(settings, params[:profile_id]) if params[:profile_id].present?
    apply_version_overrides!(settings, params)
    hook.update!(settings: settings)
    status_payload
  end

  def disconnect!
    hook&.destroy!
    @hook = nil
    DISCONNECTED_PAYLOAD.dup
  end

  def build_authenticated_client!(target_hook = hook)
    if target_hook.blank? || target_hook.disabled?
      raise Integrations::KaspiPay::ApiClient::ApiError.new('Интеграция Kaspi Pay не подключена', code: 'NotConnected')
    end

    device, token_sn, vtoken_b64 = extract_hook_secrets!(target_hook)
    s = target_hook.settings || {}
    Integrations::KaspiPay::ApiClient.new(
      device: device,
      session: { 'token_sn' => token_sn, 'vtoken_secret_b64' => vtoken_b64, 'profile_id' => s['profile_id'] },
      app_overrides: { version: VERSION_RESOLVER.sanitize_saved_version(s['app_version']), build: s['app_build'] }
    )
  end

  private

  def send_otp_with_version_retry(device, phone_10, explicit_overrides)
    client = Integrations::KaspiPay::ApiClient.new(device: device, app_overrides: explicit_overrides)
    [perform_entrance_otp(client, phone_10), explicit_overrides.merge(version: client.app_version)]
  rescue Integrations::KaspiPay::ApiClient::ApiError => e
    raise unless explicit_overrides[:version].blank? && old_version_error?(e)

    refreshed = VERSION_RESOLVER.resolve(force_refresh: true)
    raise if refreshed.blank? || refreshed == client&.app_version

    retry_overrides = explicit_overrides.merge(version: refreshed)
    retry_client = Integrations::KaspiPay::ApiClient.new(device: device, app_overrides: retry_overrides)
    [perform_entrance_otp(retry_client, phone_10), retry_overrides]
  end

  def perform_entrance_otp(client, phone_10)
    init_res = client.auth_init
    client.auth_send_phone(process_id: init_res[:process_id], phone_10: phone_10, user_token: init_res[:user_token])
  end

  def old_version_error?(err) = err.code.to_s == 'OldVersionToUpdate' || err.details.to_s.include?('OldVersionToUpdate')

  def resolve_device_identity
    existing = hook&.secret_settings&.dig('device')
    existing.is_a?(Hash) && existing['ec_private_key'].present? ? existing : Integrations::KaspiPay::Crypto.generate_device_identity
  end

  def save_pending_otp!(otp_res, device:, phone_10:, app_overrides:, explicit_overrides: {})
    payload = { 'device' => device, 'phone_10' => phone_10, 'user_token' => otp_res[:user_token],
                'app_overrides' => app_overrides.stringify_keys, 'explicit_app_overrides' => explicit_overrides.stringify_keys,
                'started_at' => Time.current.iso8601 }
    @pending_store.store!(process_id: otp_res[:process_id], payload: payload)
  end

  def complete_otp_verification!(process_id, otp, pending)
    client = Integrations::KaspiPay::ApiClient.new(device: pending.fetch('device'), app_overrides: pending['app_overrides'] || {})
    client.auth_verify_otp_and_finish(process_id: process_id, otp: otp, user_token: pending['user_token'])
  end

  def persist_connected_hook!(pending, finish_res)
    target_hook = hook || @account.hooks.build(app_id: APP_ID, hook_type: :account)
    target_hook.status = :enabled
    target_hook.access_token = { 'device' => pending.fetch('device'), 'token_sn' => finish_res[:token_sn],
                                 'vtoken_secret_b64' => finish_res[:vtoken_secret_b64] }.to_json
    target_hook.settings = build_verified_settings(target_hook.settings || {}, pending, finish_res[:org_context] || {})
    target_hook.save!
    @hook = target_hook
  end

  def build_verified_settings(prev, pending, org)
    now_iso = Time.current.iso8601
    overrides = explicit_pending_overrides(pending)
    prev.merge(
      'session_status' => 'active', 'organization_name' => org['organization_name'],
      'organization_bin' => org['organization_bin'], 'organization_id' => org['organization_id']&.to_s,
      'profile_id' => org['profile_id']&.to_s, 'organizations' => org['organizations'] || [],
      'cashier_phone_masked' => Integrations::KaspiPay::PhoneNormalizer.mask(pending['phone_10']),
      'auto_send_link_to_chat' => prev.fetch('auto_send_link_to_chat', true),
      'app_version' => overrides['version'].presence,
      'app_build' => overrides['build'].presence || prev['app_build'],
      'connected_at' => now_iso, 'last_verified_at' => now_iso, 'last_error' => nil
    ).compact
  end

  def explicit_pending_overrides(pnd) = (pnd.key?('explicit_app_overrides') ? pnd['explicit_app_overrides'] : pnd['app_overrides']) || {}

  def apply_session_check_result!(target_hook, res)
    settings = (target_hook.settings || {}).dup
    if res[:active]
      settings.merge!('session_status' => 'active', 'last_verified_at' => Time.current.iso8601, 'last_error' => nil)
    else
      settings['session_status'] = res[:evicted] ? 'reauth_required' : 'degraded'
      settings['last_error'] = res[:error]
    end
    target_hook.update!(settings: settings)
  end

  def apply_boolean_setting!(settings, params)
    return unless params.key?(:auto_send_link_to_chat)

    settings['auto_send_link_to_chat'] = ActiveModel::Type::Boolean.new.cast(params[:auto_send_link_to_chat])
  end

  def apply_profile_setting!(settings, profile_id)
    orgs = Array(settings['organizations'])
    matched = orgs.find { |org| org['profile_id'].to_s == profile_id.to_s }
    raise Integrations::KaspiPay::ApiClient::ApiError.new('Профиль филиала не найден', code: 'InvalidProfileId') if orgs.present? && matched.nil?

    settings['profile_id'] = profile_id.to_s
    return unless matched

    settings.merge!('organization_name' => matched['organization_name'], 'organization_bin' => matched['organization_bin'],
                    'organization_id' => matched['organization_id']&.to_s)
  end

  def apply_version_overrides!(settings, params)
    %i[app_version app_build].each do |field|
      next unless params.key?(field)

      raw = params[field].to_s.strip.presence
      val = field == :app_version ? VERSION_RESOLVER.sanitize_saved_version(raw) : raw
      val ? (settings[field.to_s] = val) : settings.delete(field.to_s)
    end
  end

  def extract_hook_secrets!(target_hook)
    values = target_hook.secret_settings.values_at('device', 'token_sn', 'vtoken_secret_b64')
    return values if values.all?(&:present?)

    raise Integrations::KaspiPay::ApiClient::ApiError.new('Учётные данные кассира Kaspi Pay отсутствуют.', code: 'MissingCredentials')
  end

  def build_connected_status(current_hook)
    s = current_hook.settings || {}
    DISCONNECTED_PAYLOAD.merge(
      connected: current_hook.enabled? && current_hook.secret_settings['token_sn'].present?, hook_id: current_hook.id,
      session_status: s['session_status'].presence || 'active', organization_name: s['organization_name'],
      organization_bin: s['organization_bin'], organization_id: s['organization_id'], profile_id: s['profile_id'],
      organizations: s['organizations'] || [], cashier_phone_masked: s['cashier_phone_masked'],
      auto_send_link_to_chat: s.fetch('auto_send_link_to_chat', true), app_version: s['app_version'],
      app_build: s['app_build'], connected_at: s['connected_at'], last_verified_at: s['last_verified_at'], last_error: s['last_error']
    )
  end
end
