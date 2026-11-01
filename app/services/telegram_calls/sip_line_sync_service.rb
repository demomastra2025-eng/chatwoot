class TelegramCalls::SipLineSyncService
  NATIVE_PROVIDERS = %w[asterisk_analog sipuni binotel beeline wazo].freeze
  SESSION_KEYS = %w[
    session_key sip_profile_id inbox_id provider janus_server janus_auth_token
    sip ice_servers registration_instance_id registration_config_version
  ].freeze
  LEASE_KEYS = %w[
    line_key inbox_id sip_profile_id provider session_key
    registration_instance_id registration_config_version release_key
  ].freeze

  def initialize(binding:, gateway_client: TelegramCalls::GatewaySoftphoneClient.new)
    @binding = binding
    @account = binding.account
    @user = binding.user
    @gateway_client = gateway_client
  end

  def group_key
    "account:#{@account.id}:user:#{@user.id}:binding:#{@binding.id}"
  end

  def activate!
    return { synced_lines: 0, skipped: 'voice_disabled' } unless voice_ready?

    token_payload = fetch_webphone_tokens
    return { synced_lines: 0, skipped: 'no_sip_lines' } if token_payload.blank?

    lines = build_gateway_lines(token_payload)
    return { synced_lines: 0, skipped: 'no_native_sip_sessions' } if lines.empty?

    sync_with_gateway!(lines)
  end

  def deactivate!
    remove_from_gateway
    release_lines_leases(@binding.registered_sip_lines)
    { deactivated: true }
  end

  private

  def voice_ready?
    @account.feature_enabled?('channel_voice') && @gateway_client.configured?
  end

  def webphone_service
    @webphone_service ||= Telephony::WebphoneService.new(account: @account)
  end

  def fetch_webphone_tokens
    webphone_service.token_for(
      user: @user, client_instance_id: "telegram_softphone:#{@binding.id}",
      browser_instance_id: "telegram_softphone:#{@user.id}", lease_mode: 'takeover'
    )
  rescue Telephony::Error => e
    Rails.logger.info("TELEGRAM_CALLS_SIP_SYNC_SKIPPED binding=#{@binding.id} code=#{e.code}")
    nil
  end

  def build_gateway_lines(token_payload)
    raw_sessions = Array.wrap(token_payload[:webphone_sessions] || token_payload['webphone_sessions']).presence || [token_payload]
    raw_sessions.filter_map { |raw| normalize_session_line(raw) }
  end

  def normalize_session_line(raw)
    data = raw.to_h.deep_stringify_keys
    provider = (data['provider'] || data.dig('sip', 'provider')).to_s
    return nil unless valid_native_session?(data, provider)

    inbox_id = data['inbox_id'] || data.dig('sip', 'inbox_id')
    sip_profile_id = data['sip_profile_id'] || data.dig('sip', 'sip_profile_id')
    build_line_hash(data: data, provider: provider, inbox_id: inbox_id, sip_profile_id: sip_profile_id)
  end

  def valid_native_session?(data, provider)
    NATIVE_PROVIDERS.include?(provider) && data['takeover_refused'].blank? &&
      data['janus_server'].present? && data['sip'].is_a?(Hash)
  end

  def build_line_hash(data:, provider:, inbox_id:, sip_profile_id:)
    suffix = sip_profile_id.present? ? "sip_profile:#{sip_profile_id}" : "inbox:#{inbox_id}:#{provider}"
    session_key = (data['session_key'].presence || suffix).to_s
    data.slice('janus_server', 'janus_auth_token', 'sip', 'ice_servers',
               'registration_instance_id', 'registration_config_version').merge(
                 'line_key' => "#{group_key}:#{session_key}", 'session_key' => session_key,
                 'account_id' => @account.id, 'user_id' => @user.id, 'inbox_id' => inbox_id,
                 'sip_profile_id' => sip_profile_id, 'provider' => provider,
                 'release_key' => data['registration_release_key']
               )
  end

  def sync_with_gateway!(lines)
    response = @gateway_client.sync_sip_lines!(build_gateway_sync_payload(lines))
    persisted = persist_synced_lines!(lines, response)
    ensure_at_least_one_registered!(lines, persisted)
    { synced_lines: persisted.count { |item| item['registered'] }, lines: persisted }
  rescue StandardError => e
    rollback_failed_sync!(lines)
    raise e if e.is_a?(Telephony::Error)

    raise Telephony::Error.new(code: 'TELEGRAM_SIP_SYNC_FAILED', message: e.message, status: :bad_gateway)
  end

  def build_gateway_sync_payload(lines)
    {
      line_group_key: group_key, account_id: @account.id, user_id: @user.id,
      operator_telegram_user_id: @binding.telegram_user_id.to_s,
      callback_url: TelegramCalls::Config.callback_url.presence,
      callback_token: TelegramCalls::Config.callback_token.presence,
      sessions: lines.map { |line| line.slice(*SESSION_KEYS).compact }
    }
  end

  def persist_synced_lines!(requested_lines, response)
    gateway_lines = Array.wrap(response['registered_lines'].presence || response['lines'])
    errors_map = response['errors'].is_a?(Hash) ? response['errors'].stringify_keys : {}
    by_key = gateway_lines.index_by { |item| item.to_h['line_key'].to_s }
    persisted = requested_lines.map do |line|
      build_persisted_line(line, by_key[line['line_key']].to_h, errors_map[line['line_key']])
    end
    @binding.update!(sip_lease_meta: { 'group_key' => group_key, 'lines' => persisted })
    persisted
  end

  def build_persisted_line(line, gw_row, error_override)
    registered = gw_row['registered'] == true
    mark_webphone_presence(line, gw_row, registered: registered)
    err = error_override.presence || gw_row['error']
    line.slice(*LEASE_KEYS).merge('registered' => registered, 'error' => err).compact
  end

  def ensure_at_least_one_registered!(requested_lines, persisted)
    return if requested_lines.empty? || persisted.any? { |item| item['registered'] }

    first_err = persisted.filter_map { |item| item['error'].presence }.first
    raise Telephony::Error.new(
      code: 'TELEGRAM_SIP_REGISTRATION_FAILED',
      message: first_err || 'Не удалось зарегистрировать SIP-линию в голосовом шлюзе',
      status: :unprocessable_content
    )
  end

  def rollback_failed_sync!(lines)
    remove_from_gateway
    release_lines_leases(lines)
    @binding.update!(sip_lease_meta: {}) if @binding.persisted?
  end

  def mark_webphone_presence(line, gw_state, registered:)
    inbox = @account.inboxes.find_by(id: line['inbox_id'])
    ctx = line.slice('sip_profile_id', 'inbox_id', 'session_key',
                     'registration_instance_id', 'registration_config_version')
              .merge(gw_state.slice('janus_session_id', 'janus_handle_id')).compact
    webphone_service.update_presence!(user: @user, inbox: inbox, registered: registered, registration_context: ctx)
  rescue StandardError => e
    Rails.logger.warn("TELEGRAM_CALLS_PRESENCE_SYNC_ERROR binding=#{@binding.id} error=#{e.message}")
  end

  def remove_from_gateway
    saved_group = @binding.sip_lease_meta.to_h['group_key'].presence || group_key
    @gateway_client.remove_sip_line_group!(group_key: saved_group) if @gateway_client.configured?
  rescue StandardError => e
    Rails.logger.warn("TELEGRAM_CALLS_SIP_REMOVE_WARN binding=#{@binding.id} error=#{e.message}")
  end

  def release_lines_leases(lines)
    Array.wrap(lines).each do |line|
      if line['release_key'].present?
        webphone_service.release_registration_lease!(release_key: line['release_key'])
      else
        mark_webphone_presence(line, {}, registered: false)
      end
    rescue StandardError => e
      Rails.logger.warn("TELEGRAM_CALLS_LEASE_RELEASE_WARN binding=#{@binding.id} error=#{e.message}")
    end
  end
end
