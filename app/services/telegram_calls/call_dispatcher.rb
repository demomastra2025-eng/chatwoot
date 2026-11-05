class TelegramCalls::CallDispatcher
  class << self
    def dispatch_whatsapp_call(call)
      return [] unless dispatchable_call?(call)

      meta = build_call_meta(call: call, source_type: 'whatsapp')
      new(account: call.account, inbox: call.inbox, meta: meta).dispatch!
    rescue StandardError => e
      Rails.logger.warn("TELEGRAM_CALLS_DISPATCH_WA_ERROR call_id=#{call&.id} error=#{e.class}: #{e.message}")
      []
    end

    def dispatch_telegram_personal_call(call)
      return [] unless dispatchable_call?(call)

      meta = build_call_meta(call: call, source_type: 'telegram_personal')
      new(account: call.account, inbox: call.inbox, meta: meta).dispatch!
    rescue StandardError => e
      Rails.logger.warn("TELEGRAM_CALLS_DISPATCH_TGP_ERROR call_id=#{call&.id} error=#{e.class}: #{e.message}")
      []
    end

    def dispatch_telephony_call(call_session, line_key: nil, janus_call_id: nil, target_user_ids: nil)
      return [] if call_session.blank? || call_session.terminal? || !TelegramCalls::Config.configured?

      meta = build_telephony_meta(call_session: call_session, line_key: line_key, janus_call_id: janus_call_id)
      new(
        account: call_session.account, inbox: call_session.inbox, meta: meta,
        target_user_ids: target_user_ids, excluding_telephony_call_ref: call_session.external_call_ref
      ).dispatch!
    rescue StandardError => e
      Rails.logger.warn("TELEGRAM_CALLS_DISPATCH_SIP_ERROR ref=#{call_session&.external_call_ref} error=#{e.class}: #{e.message}")
      []
    end

    def cancel_legs_for_source!(source_type:, account_id:, source_call_ref:, status_text:, **)
      TelegramCalls::LegCanceller.cancel_for_source!(
        source_type: source_type, account_id: account_id, source_call_ref: source_call_ref,
        status_text: status_text, **
      )
    end

    def cancel_single_leg!(leg_id:, status_text:, decline_sip: false)
      TelegramCalls::LegCanceller.cancel_single_leg!(leg_id: leg_id, status_text: status_text, decline_sip: decline_sip)
    end

    private

    def dispatchable_call?(call)
      call.present? && call.incoming? && call.ringing? && TelegramCalls::Config.configured?
    end

    def build_call_meta(call:, source_type:)
      contact = call.contact
      {
        'source_type' => source_type, 'source_call_ref' => call.id.to_s,
        'caller_title' => contact&.name.presence || contact&.phone_number.presence || 'Клиент',
        'caller_phone' => contact&.phone_number.presence, 'inbox_name' => call.inbox&.name,
        'crm_summary' => TelegramCalls::CallerCardBuilder.crm_summary_for_contact(account: call.account, contact: contact),
        'conversation_url' => TelegramCalls::Config.conversation_url(
          account_id: call.account_id, conversation_display_id: call.conversation&.display_id
        )
      }
    end

    def build_telephony_meta(call_session:, line_key:, janus_call_id:)
      contact = call_session.contact
      {
        'source_type' => 'telephony_sip', 'source_call_ref' => call_session.external_call_ref.to_s,
        'logical_group_ref' => call_session.try(:logical_call_group_ref),
        'line_key' => line_key, 'janus_call_id' => janus_call_id,
        'provider_label' => TelegramCalls::CallerCardBuilder.provider_label(call_session.provider),
        'caller_title' => contact&.name.presence || call_session.from_number.presence || 'Клиент',
        'caller_phone' => call_session.from_number.presence || contact&.phone_number.presence,
        'inbox_name' => call_session.inbox&.name,
        'crm_summary' => TelegramCalls::CallerCardBuilder.crm_summary_for_contact(account: call_session.account, contact: contact),
        'conversation_url' => TelegramCalls::Config.conversation_url(
          account_id: call_session.account_id, conversation_display_id: call_session.conversation&.display_id
        )
      }.compact
    end
  end

  def initialize(account:, inbox:, meta:, target_user_ids: nil, excluding_telephony_call_ref: nil)
    @account = account
    @inbox = inbox
    @meta = meta.deep_stringify_keys
    @target_user_ids = Array.wrap(target_user_ids).filter_map { |id| id.presence&.to_i }
    @excluding_telephony_call_ref = excluding_telephony_call_ref
    @bot_client = TelegramCalls::BotClient.new
    @gateway_client = TelegramCalls::GatewaySoftphoneClient.new
  end

  def dispatch!
    return [] unless TelegramCalls::Config.enabled_for?(@account)

    bindings = eligible_bindings
    return [] if bindings.empty?

    group_id = existing_group&.dig('group_id') || SecureRandom.uuid
    bindings.filter_map { |binding| dispatch_to_binding(binding, group_id: group_id) }
  end

  private

  def eligible_bindings
    scope = @account.telephony_telegram_operator_bindings.on_line.includes(:user)
    scope = scope.where(user_id: @target_user_ids) if @target_user_ids.present?
    candidates = scope.to_a.select { |binding| inbox_member?(binding.user_id) && !already_dispatched?(binding.id) }
    return [] if candidates.empty?

    busy_ids = compute_busy_user_ids(candidates.map(&:user_id))
    candidates.reject { |binding| busy_ids.include?(binding.user_id) }
  end

  def inbox_member?(user_id)
    return true if @inbox.blank? || !@inbox.inbox_members.exists?

    @inbox.inbox_members.exists?(user_id: user_id)
  end

  def compute_busy_user_ids(user_ids)
    Telephony::OperatorBusyService.busy_user_ids(
      account: @account,
      user_ids: user_ids,
      excluding_telephony_call_ref: @excluding_telephony_call_ref
    )
  end

  def existing_group
    @existing_group ||= TelegramCalls::Registry.fetch_source_group(
      source_type: @meta['source_type'], account_id: @account.id, source_call_ref: @meta['source_call_ref']
    )
  end

  def already_dispatched?(binding_id)
    return false if existing_group.blank?

    Array.wrap(existing_group['leg_ids']).any? do |leg_id|
      TelegramCalls::Registry.fetch_leg(leg_id)&.dig('binding_id').to_i == binding_id.to_i
    end
  end

  def dispatch_to_binding(binding, group_id:)
    return unless TelegramCalls::Config.enabled_for?(@account)

    leg_id = SecureRandom.uuid
    leg_meta = build_leg_record(binding: binding, leg_id: leg_id, group_id: group_id)
    TelegramCalls::Registry.store_leg!(leg_meta)
    TelegramCalls::Registry.append_leg_to_source!(
      source_type: @meta['source_type'], account_id: @account.id,
      source_call_ref: @meta['source_call_ref'], leg_id: leg_id, group_id: group_id
    )
    send_card_and_voice_ring!(binding: binding, leg_meta: leg_meta)
  end

  def build_leg_record(binding:, leg_id:, group_id:)
    @meta.merge(
      'leg_id' => leg_id, 'group_id' => group_id, 'account_id' => @account.id,
      'inbox_id' => @inbox&.id, 'user_id' => binding.user_id, 'binding_id' => binding.id,
      'chat_id' => binding.telegram_chat_id, 'status' => 'ringing', 'voice_ring_started' => false
    )
  end

  def send_card_and_voice_ring!(binding:, leg_meta:)
    text = TelegramCalls::CallerCardBuilder.build_text(meta: leg_meta, status_line: ringing_status_line(leg_meta))
    markup = TelegramCalls::BotClient.call_inline_keyboard(
      leg_id: leg_meta['leg_id'], conversation_url: leg_meta['conversation_url'], state: :ringing
    )
    msg = @bot_client.send_message(chat_id: binding.telegram_chat_id, text: text, reply_markup: markup)
    TelegramCalls::Registry.update_leg!(leg_meta['leg_id'], 'message_id' => msg&.dig('message_id'))
    voice_started = start_gateway_voice_leg(binding: binding, leg_meta: leg_meta)
    TelegramCalls::Registry.update_leg!(leg_meta['leg_id'], 'voice_ring_started' => voice_started)
  end

  def ringing_status_line(leg_meta)
    return '🔔 <b>Входящий вызов</b> — ответьте на звонок в Telegram' if leg_meta['source_type'] == 'telephony_sip'

    '🔔 <b>Входящий вызов</b> — ответьте на звонок в Telegram или в браузере OneLink'
  end

  def start_gateway_voice_leg(binding:, leg_meta:)
    return false if TelegramCalls::LegCanceller.cancel_if_disabled!(account: @account, leg_id: leg_meta['leg_id'])
    return false unless @gateway_client.configured? && TelegramCalls::Config.callback_url.present?

    @gateway_client.create_leg!(gateway_create_leg_payload(binding: binding, leg_meta: leg_meta))
    true
  rescue StandardError => e
    Rails.logger.warn("TELEGRAM_CALLS_CREATE_LEG_WARN leg=#{leg_meta['leg_id']} error=#{e.message}")
    false
  end

  def gateway_create_leg_payload(binding:, leg_meta:)
    {
      leg_id: leg_meta['leg_id'],
      source_type: leg_meta['source_type'],
      source_call_ref: leg_meta['source_call_ref'],
      account_id: @account.id,
      user_id: binding.user_id,
      operator_telegram_user_id: binding.telegram_user_id.to_s,
      operator_telegram_username: binding.username,
      operator_phone: binding.phone_number,
      callback_url: TelegramCalls::Config.callback_url.presence,
      callback_token: TelegramCalls::Config.callback_token.presence,
      metadata: { group_id: leg_meta['group_id'], caller_label: leg_meta['caller_title'] }.compact
    }
  end
end
