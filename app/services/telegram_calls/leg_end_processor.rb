class TelegramCalls::LegEndProcessor
  def initialize(leg:, payload:, gateway_client: TelegramCalls::GatewaySoftphoneClient.new)
    @leg = leg
    @payload = payload.to_h.deep_stringify_keys
    @gateway_client = gateway_client
  end

  def perform
    account = Account.find_by(id: @leg['account_id'])
    upload_sip_recording(account: account) if account
    return handle_already_terminal_leg if terminal_without_force?

    TelegramCalls::Registry.update_leg!(@leg['leg_id'], 'status' => 'ended')
    if active_claimed_leg?
      finalize_active_call!(account: account)
    else
      handle_unclaimed_end!
    end
    { ok: true, ended: true }
  end

  private

  def active_claimed_leg?
    @leg['claimed'] || @leg['source_type'] == 'telephony_sip_outbound'
  end

  def terminal_without_force?
    return true if @leg['status'] == 'ended'

    @leg['status'] == 'cancelled' && !@payload['force_finalize']
  end

  def handle_already_terminal_leg
    if active_claimed_leg? && @payload['duration_seconds'].to_i.positive?
      TelegramCalls::LegCanceller.update_card_status(@leg, ended_status_line, state: :ended)
    end
    @leg['status'] == 'ended' ? { ok: true, already_ended: true } : { ok: true, already_cancelled: true }
  end

  def finalize_active_call!(account:)
    user = account&.users&.find_by(id: @leg['user_id'])
    return unless account && user

    terminate_underlying_call(account: account, user: user)
    TelegramCalls::LegCanceller.update_card_status(@leg, ended_status_line, state: :ended)
  end

  def upload_sip_recording(account:)
    return unless @payload['has_recording'] == true && sip_source?

    call_session = account.telephony_call_sessions.find_by(external_call_ref: @leg['source_call_ref'])
    return if call_session.blank? || call_session.recording_ref.present?
    return unless TelegramCalls::Registry.try_lock_recording_upload!(@leg['leg_id'])

    ogg_bytes = @gateway_client.download_recording!(leg_id: @leg['leg_id'])
    upload_ogg_bytes!(call_session: call_session, ogg_bytes: ogg_bytes)
  rescue StandardError => e
    Rails.logger.warn("TELEGRAM_CALLS_REC_UPLOAD_WARN leg=#{@leg['leg_id']} error=#{e.message}")
  end

  def upload_ogg_bytes!(call_session:, ogg_bytes:)
    Tempfile.create(['tg_softphone_rec_', '.ogg'], binmode: true) do |file|
      file.write(ogg_bytes)
      file.rewind
      uploaded = ActionDispatch::Http::UploadedFile.new(
        tempfile: file, filename: "call-#{call_session.id}.ogg", type: 'audio/ogg'
      )
      Telephony::BrowserRecordingUploadService.perform!(
        call_session: call_session, recording: uploaded, duration_seconds: @payload['duration_seconds']
      )
    end
  end

  def terminate_underlying_call(account:, user:)
    if @leg['source_type'] == 'whatsapp'
      terminate_whatsapp_call(account: account, user: user)
    elsif @leg['source_type'] == 'telegram_personal'
      terminate_telegram_personal_call(account: account, user: user)
    elsif sip_source?
      release_telephony_session(account: account, user: user, status: 'completed')
    end
  rescue StandardError => e
    Rails.logger.info("TELEGRAM_CALLS_END_SYNC_INFO leg=#{@leg['leg_id']} error=#{e.message}")
  end

  def terminate_whatsapp_call(account:, user:)
    call = account.calls.whatsapp.find_by(id: @leg['source_call_ref'])
    Whatsapp::CallService.new(call: call, agent: user).terminate if call && !call.terminal?
  end

  def terminate_telegram_personal_call(account:, user:)
    call = account.calls.telegram_personal.find_by(id: @leg['source_call_ref'])
    TelegramPersonal::CallService.new(call: call, agent: user).terminate if call && !call.terminal?
  end

  def handle_unclaimed_end!
    TelegramCalls::LegCanceller.update_card_status(@leg, '❌ Вызов отклонён или завершён', state: :ended)
    return unless @leg['source_type'] == 'telephony_sip' && sole_remaining_ringing_leg?

    decline_sole_sip_leg!
  end

  def sole_remaining_ringing_leg?
    group = TelegramCalls::Registry.fetch_source_group(
      source_type: @leg['source_type'], account_id: @leg['account_id'], source_call_ref: @leg['source_call_ref']
    )
    other_ids = Array.wrap(group&.dig('leg_ids')) - [@leg['leg_id']]
    other_ids.none? { |id| TelegramCalls::Registry.fetch_leg(id)&.dig('status') == 'ringing' }
  end

  def decline_sole_sip_leg!
    decline_gateway_sip_line
    account = Account.find_by(id: @leg['account_id'])
    user = account&.users&.find_by(id: @leg['user_id'])
    release_telephony_session(account: account, user: user, status: 'rejected') if account && user
  rescue StandardError
    nil
  end

  def decline_gateway_sip_line
    return unless @leg['line_key'].present? && @gateway_client.configured?

    @gateway_client.decline_sip_call!(
      line_key: @leg['line_key'], janus_call_id: @leg['janus_call_id'], call_ref: @leg['source_call_ref']
    )
  end

  def release_telephony_session(account:, user:, status:)
    call_ref = @leg['source_call_ref']
    session = account.telephony_call_sessions.find_by(external_call_ref: call_ref)
    return if session.blank? || session.terminal?

    Telephony::OperatorCallRejectService.new(
      account: account, user: user, call_ref: call_ref, status: status, reason: 'telegram_softphone_end'
    ).perform
  end

  def sip_source?
    @leg['source_type'].in?(%w[telephony_sip telephony_sip_outbound])
  end

  def ended_status_line
    dur = @payload['duration_seconds'].to_i
    dur.positive? ? "✅ <b>Звонок завершён</b> (#{dur} сек.)" : '✅ <b>Звонок завершён</b>'
  end
end
