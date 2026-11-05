class TelegramCalls::SipEventProcessor
  include TelegramCalls::SipEventAccess

  SIP_URI_USER_REGEX = /\Asips?:([^@;>]+)/i
  LEASE_CONFLICT_REASONS = %w[sip_profile_registration_lease_conflict sip_profile_registration_context_stale].freeze
  HEARTBEAT_KEYS = %w[sip_profile_id inbox_id session_key registration_instance_id
                      registration_config_version janus_session_id janus_handle_id presence_sequence].freeze
  INCOMING_REPORT_KEYS = %w[provider to_number session_key sip_profile_id janus_session_id
                            janus_handle_id registration_instance_id registration_config_version].freeze

  def initialize(payload:)
    @payload = payload.to_h.deep_stringify_keys
  end

  def perform
    account = Account.find_by(id: @payload['account_id'])
    user = account&.users&.find_by(id: @payload['user_id'])
    return { ignored: 'tenant_not_found' } unless account && user

    return { ignored: 'telegram_calls_bot_disabled' } if revoke_disabled_line?(account: account, user: user)

    dispatch_sip_event(account: account, user: user)
  end

  private

  def dispatch_sip_event(account:, user:)
    case @payload['event_type']
    when 'sip_line.heartbeat' then handle_heartbeat(account: account, user: user)
    when 'sip_line.incoming_call' then handle_incoming_call(account: account, user: user)
    when 'sip_line.call_accepted' then handle_call_accepted(account: account, user: user)
    when 'sip_line.call_hangup' then handle_call_hangup(account: account, user: user)
    when 'sip_line.disconnected' then handle_disconnected(account: account, user: user)
    else { ignored: @payload['event_type'] }
    end
  end

  def handle_heartbeat(account:, user:)
    res = report_presence!(account: account, user: user, registered: @payload['registered'] != false)
    yield_line_to_browser_if_taken_over!(account: account, user: user, result: res)
    { ok: true }
  end

  def report_presence!(account:, user:, registered:)
    inbox = account.inboxes.find_by(id: @payload['inbox_id'])
    Telephony::WebphoneService.new(account: account).update_presence!(
      user: user, inbox: inbox, registered: registered, registration_context: @payload.slice(*HEARTBEAT_KEYS)
    )
  end

  def yield_line_to_browser_if_taken_over!(account:, user:, result:)
    return false unless browser_took_over_lease?(result)

    binding = account.telephony_telegram_operator_bindings.find_by(user_id: user.id)
    if binding&.on_line?
      saved_group = binding.sip_lease_meta.to_h['group_key'].presence ||
                    TelegramCalls::SipLineSyncService.new(binding: binding).group_key
      client = TelegramCalls::GatewaySoftphoneClient.new
      client.remove_sip_line_group!(group_key: saved_group) if client.configured?
      binding.update!(on_line: false, on_line_since: nil, sip_lease_meta: {})
    end
    true
  rescue StandardError => e
    Rails.logger.warn("TELEGRAM_CALLS_YIELD_TO_BROWSER_WARN user_id=#{user.id} error=#{e.message}")
    true
  end

  def browser_took_over_lease?(result)
    data = result.to_h.deep_stringify_keys
    return true if data['registration_lease_active'] == false

    data['presence_update_accepted'] == false && LEASE_CONFLICT_REASONS.include?(data['reason'].to_s)
  end

  def handle_incoming_call(account:, user:)
    inbox = account.inboxes.find_by(id: @payload['inbox_id'])
    return { ignored: 'inbox_not_found' } unless inbox

    report = Telephony::WebphoneService.new(account: account).report_browser_sip_incoming!(
      user: user, inbox: inbox, params: incoming_report_params
    )
    call_ref = (report[:call_ref] || report['call_ref'] || @payload['call_ref']).to_s
    TelegramCalls::Registry.store_janus_call_map!(
      account_id: account.id, line_key: @payload['line_key'], janus_call_id: @payload['janus_call_id'], call_ref: call_ref
    )
    return { ok: true, call_ref: call_ref, ai_voice: true } if (report[:ai_voice] || report['ai_voice']).present?

    dispatch_or_decline_incoming_sip!(account: account, user: user, call_ref: call_ref)
  end

  def dispatch_or_decline_incoming_sip!(account:, user:, call_ref:)
    call_session = account.telephony_call_sessions.find_by(external_call_ref: call_ref)
    if call_session.blank? || call_session.terminal?
      decline_stale_gateway_incoming!(call_ref)
      return { ok: true, call_ref: call_ref, declined: true }
    end

    TelegramCalls::CallDispatcher.dispatch_telephony_call(
      call_session, line_key: @payload['line_key'], janus_call_id: @payload['janus_call_id'], target_user_ids: [user.id]
    )
    { ok: true, call_ref: call_ref }
  end

  def decline_stale_gateway_incoming!(call_ref)
    client = TelegramCalls::GatewaySoftphoneClient.new
    return unless @payload['line_key'].present? && client.configured?

    client.decline_sip_call!(line_key: @payload['line_key'], janus_call_id: @payload['janus_call_id'], call_ref: call_ref.presence)
  rescue StandardError
    nil
  end

  def handle_call_accepted(account:, user:)
    call_ref = resolve_sip_call_ref(account)
    call_session = account.telephony_call_sessions.find_by(external_call_ref: call_ref)
    if call_session&.direction == 'outbound'
      Telephony::OperatorCallAnsweredService.new(account: account, user: user, call_ref: call_ref).perform
      mark_outbound_card_in_progress(account.id, call_ref)
    end
    { ok: true }
  end

  def mark_outbound_card_in_progress(account_id, call_ref)
    group = TelegramCalls::Registry.fetch_source_group(
      source_type: 'telephony_sip_outbound', account_id: account_id, source_call_ref: call_ref
    )
    leg_id = @payload['leg_id'].presence || Array.wrap(group&.dig('leg_ids')).first
    leg = TelegramCalls::Registry.fetch_leg(leg_id)
    TelegramCalls::LegCanceller.update_card_status(leg, '🟢 <b>Разговор идёт</b>', state: :active) if leg.present?
  end

  def handle_call_hangup(account:, user:)
    leg = TelegramCalls::Registry.fetch_leg(@payload['leg_id'])
    TelegramCalls::LegEndProcessor.new(leg: leg, payload: @payload).perform if leg.present?
    call_ref = resolve_sip_call_ref(account)
    if call_ref.present?
      terminate_session_on_remote_hangup!(account: account, user: user, call_ref: call_ref)
      cancel_telegram_legs_for_hangup(account.id, call_ref)
    end
    { ok: true }
  end

  def terminate_session_on_remote_hangup!(account:, user:, call_ref:)
    call_session = account.telephony_call_sessions.find_by(external_call_ref: call_ref)
    return unless call_session && !call_session.terminal?

    status = call_session.answered_at.present? ? 'completed' : 'cancelled'
    Telephony::OperatorCallRejectService.new(
      account: account, user: user, call_ref: call_ref, status: status, reason: 'remote_hangup'
    ).perform
  end

  def resolve_sip_call_ref(account)
    @payload['call_ref'].to_s.strip.presence ||
      TelegramCalls::Registry.fetch_leg(@payload['leg_id'])&.dig('source_call_ref').presence ||
      mapped_or_db_janus_call_ref(account)
  end

  def mapped_or_db_janus_call_ref(account)
    janus_id = @payload['janus_call_id'].to_s
    return '' if janus_id.blank?

    mapped = TelegramCalls::Registry.resolve_janus_call_ref(account_id: account.id, line_key: @payload['line_key'], janus_call_id: janus_id)
    return mapped if mapped.present?

    account.telephony_call_sessions.where('external_call_ref LIKE ?', "%:#{ActiveRecord::Base.sanitize_sql_like(janus_id)}")
           .order(id: :desc).pick(:external_call_ref).to_s
  end

  def cancel_telegram_legs_for_hangup(account_id, call_ref)
    %w[telephony_sip telephony_sip_outbound].each do |src|
      TelegramCalls::CallDispatcher.cancel_legs_for_source!(source_type: src, account_id: account_id, source_call_ref: call_ref,
                                                            status_text: '✅ <b>Звонок завершён</b>', include_claimed: true)
    end
  end

  def handle_disconnected(account:, user:)
    res = report_presence!(account: account, user: user, registered: false)
    return { ok: true } if yield_line_to_browser_if_taken_over!(account: account, user: user, result: res)

    recover_or_mark_disconnected_binding!(account: account, user: user)
    { ok: true }
  end

  def recover_or_mark_disconnected_binding!(account:, user:)
    binding = account.telephony_telegram_operator_bindings.find_by(user_id: user.id)
    return unless binding

    mark_binding_line_unregistered!(binding)
    TelegramCalls::SipLineSyncService.new(binding: binding).activate! if binding.on_line?
  rescue Telephony::Error
    binding&.update!(on_line: false, on_line_since: nil)
  end

  def mark_binding_line_unregistered!(binding)
    meta = binding.sip_lease_meta.to_h.deep_stringify_keys
    return if meta['lines'].blank?

    meta['lines'] = Array.wrap(meta['lines']).map { |l| l['line_key'] == @payload['line_key'] ? l.merge('registered' => false) : l }
    binding.update!(sip_lease_meta: meta)
  end

  def incoming_report_params
    base = @payload.slice(*INCOMING_REPORT_KEYS)
    base['call_ref'] = (@payload['call_ref'].presence || @payload['janus_call_id']).to_s
    from_num = @payload['from_number'].presence || extract_sip_user(@payload['from_uri']) || @payload['display_name'].presence
    base['from_number'] = from_num if from_num.present?
    base
  end

  def extract_sip_user(uri)
    match = uri.to_s.strip.match(SIP_URI_USER_REGEX)
    match ? URI::DEFAULT_PARSER.unescape(match[1]).strip.presence : nil
  end
end
