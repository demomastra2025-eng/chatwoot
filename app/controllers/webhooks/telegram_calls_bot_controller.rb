class Webhooks::TelegramCallsBotController < ApplicationController
  skip_before_action :verify_authenticity_token, raise: false

  PHONE_PATTERN = /\A\+?\d[\d\s\-()]{6,}\z/

  def process_payload
    return head :unauthorized unless valid_webhook_secret?

    if params[:callback_query].present?
      handle_callback_query(params[:callback_query].to_unsafe_h.deep_stringify_keys)
    elsif params[:message].present?
      handle_message(params[:message].to_unsafe_h.deep_stringify_keys)
    end
    head :ok
  end

  private

  def valid_webhook_secret?
    expected = TelegramCalls::Config.webhook_secret
    provided = request.headers['X-Telegram-Bot-Api-Secret-Token'].to_s.presence || params[:webhook_secret].to_s
    expected.present? && provided.bytesize == expected.bytesize &&
      ActiveSupport::SecurityUtils.secure_compare(provided, expected)
  end

  def bot_client
    @bot_client ||= TelegramCalls::BotClient.new
  end

  def handle_message(message)
    chat_id = message.dig('chat', 'id')&.to_s
    from = message['from'].to_h
    return if chat_id.blank? || from['id'].blank?
    return handle_shared_contact(chat_id: chat_id, from: from, contact: message['contact']) if message['contact'].present?

    dispatch_text_command(chat_id: chat_id, from: from, text: message['text'].to_s.strip)
  end

  def dispatch_text_command(chat_id:, from:, text:)
    tg_id = from['id'].to_s
    if text.start_with?('/start')
      handle_start_command(chat_id: chat_id, from: from, raw_token: text.split(/\s+/, 2)[1].to_s.strip)
    elsif text.in?([TelegramCalls::BotClient::ON_LINE_BUTTON, '/online'])
      toggle_bindings_line!(chat_id: chat_id, tg_user_id: tg_id, on_line: true)
    elsif text.in?([TelegramCalls::BotClient::OFF_LINE_BUTTON, '/offline'])
      toggle_bindings_line!(chat_id: chat_id, tg_user_id: tg_id, on_line: false)
    elsif text.in?([TelegramCalls::BotClient::STATUS_BUTTON, '/status'])
      reply_status(chat_id: chat_id, tg_user_id: tg_id)
    else
      handle_dial_command(chat_id: chat_id, tg_user_id: tg_id, text: text)
    end
  end

  def handle_start_command(chat_id:, from:, raw_token:)
    return reply_status(chat_id: chat_id, tg_user_id: from['id'].to_s) if raw_token.blank?

    binding = Telephony::TelegramOperatorBinding.consume_link_token!(raw_token, from: from, chat_id: chat_id)
    return send_linked_welcome(chat_id: chat_id, binding: binding) if binding

    bot_client.send_message(
      chat_id: chat_id,
      text: '❌ Ссылка устарела или уже использована. Сгенерируйте новую кнопку подключения в OneLink.'
    )
  end

  def send_linked_welcome(chat_id:, binding:)
    ws = ERB::Util.html_escape(binding.account.name)
    text = "✅ <b>Telegram подключён к OneLink</b> (#{ws}).\n\nНажмите <b>«🟢 Выйти на линию»</b> для приёма звонков."
    markup = TelegramCalls::BotClient.operator_reply_keyboard(on_line: binding.on_line?, needs_phone: binding.phone_number.blank?)
    bot_client.send_message(chat_id: chat_id, text: text, reply_markup: markup)
  end

  def handle_shared_contact(chat_id:, from:, contact:)
    bindings = connected_bindings(from['id'].to_s)
    return reply_unlinked(chat_id) if bindings.empty?

    if contact['user_id'].to_s != from['id'].to_s
      return bot_client.send_message(chat_id: chat_id, text: '⚠️ Отправьте ваш собственный контакт кнопкой на клавиатуре.')
    end

    bindings.each { |binding| binding.update_verified_phone!(contact['phone_number']) }
    bot_client.send_message(
      chat_id: chat_id, text: '✅ Ваш номер телефона привязан к линии звонков OneLink.',
      reply_markup: TelegramCalls::BotClient.operator_reply_keyboard(on_line: bindings.any?(&:on_line?), needs_phone: false)
    )
  end

  def toggle_bindings_line!(chat_id:, tg_user_id:, on_line:)
    bindings = connected_bindings(tg_user_id)
    return reply_unlinked(chat_id) if bindings.empty?

    bindings.each { |binding| toggle_single_binding!(chat_id: chat_id, binding: binding, on_line: on_line) }
    reply_status(chat_id: chat_id, tg_user_id: tg_user_id)
  end

  def toggle_single_binding!(chat_id:, binding:, on_line:)
    on_line ? binding.go_on_line! : binding.go_off_line!
  rescue Telephony::Error => e
    ws = ERB::Util.html_escape(binding.account.name)
    bot_client.send_message(chat_id: chat_id, text: "⚠️ <b>#{ws}:</b> #{ERB::Util.html_escape(e.message)}")
  end

  def reply_status(chat_id:, tg_user_id:)
    bindings = connected_bindings(tg_user_id)
    return reply_unlinked(chat_id) if bindings.empty?

    markup = TelegramCalls::BotClient.operator_reply_keyboard(
      on_line: bindings.any?(&:on_line?), needs_phone: bindings.any? { |item| item.phone_number.blank? }
    )
    bot_client.send_message(chat_id: chat_id, text: bindings.map { |b| format_binding_status(b) }.join("\n\n"), reply_markup: markup)
  end

  def format_binding_status(binding)
    badge = binding.on_line? ? '🟢 <b>На линии</b>' : '⚪ <b>Не на линии</b>'
    sip_count = binding.registered_sip_lines.count { |line| line['registered'] }
    parts = ["#{badge} · <b>#{ERB::Util.html_escape(binding.account.name)}</b>"]
    parts << "📞 Активных SIP-линий: #{sip_count}" if sip_count.positive?
    parts << '💡 Для исходящего звонка отправьте номер, например <code>+77011234567</code>' if binding.on_line? && sip_count.positive?
    parts.join("\n")
  end

  def handle_dial_command(chat_id:, tg_user_id:, text:)
    raw_number = extract_dial_number(text)
    return if raw_number.blank?

    bindings = connected_bindings(tg_user_id)
    return reply_unlinked(chat_id) if bindings.empty?

    dial_or_prompt_workspace!(chat_id: chat_id, bindings: bindings, raw_number: raw_number)
  rescue Telephony::Error => e
    bot_client.send_message(chat_id: chat_id, text: "⚠️ #{ERB::Util.html_escape(e.message)}")
  end

  def extract_dial_number(text)
    text.start_with?('/call') ? text.sub(%r{\A/call\s*}, '') : (text if text.match?(PHONE_PATTERN))
  end

  def dial_or_prompt_workspace!(chat_id:, bindings:, raw_number:)
    ready = bindings.select { |item| item.on_line? && item.registered_sip_lines.any? { |line| line['registered'] } }
    return prompt_workspace_for_dial(chat_id: chat_id, bindings: ready, raw_number: raw_number) if ready.size > 1

    TelegramCalls::OutboundDialService.new(binding: ready.first || bindings.first, raw_number: raw_number).perform!
  end

  def prompt_workspace_for_dial(chat_id:, bindings:, raw_number:)
    normalized = TelegramCalls::OutboundDialService.normalize_number(raw_number)
    if normalized.blank?
      raise Telephony::Error.new(code: 'INVALID_PHONE_NUMBER', message: 'Укажите корректный номер телефона', status: :unprocessable_content)
    end

    digits = normalized.delete_prefix('+')
    rows = bindings.map { |item| [{ text: "📞 #{item.account.name}", callback_data: "dialws:#{item.id}:#{digits}" }] }
    bot_client.send_message(
      chat_id: chat_id,
      text: "Выберите рабочее пространство для звонка на <code>#{ERB::Util.html_escape(normalized)}</code>:",
      reply_markup: { inline_keyboard: rows }
    )
  end

  def handle_callback_query(query)
    cb_id = query['id']
    tg_user_id = query.dig('from', 'id')&.to_s
    action, rest = query['data'].to_s.split(':', 2)
    return bot_client.answer_callback_query(callback_query_id: cb_id) if rest.blank? || tg_user_id.blank?
    return process_dial_workspace_callback(cb_id: cb_id, tg_user_id: tg_user_id, rest: rest) if action == 'dialws'

    process_leg_callback_action(cb_id: cb_id, tg_user_id: tg_user_id, action: action, leg_id: rest)
  end

  def process_dial_workspace_callback(cb_id:, tg_user_id:, rest:)
    binding_id, digits = rest.split(':', 2)
    binding = connected_bindings(tg_user_id).find { |item| item.id == binding_id.to_i }
    return bot_client.answer_callback_query(callback_query_id: cb_id, text: 'Линия недоступна', show_alert: true) unless binding && digits.present?

    TelegramCalls::OutboundDialService.new(binding: binding, raw_number: "+#{digits}").perform!
    bot_client.answer_callback_query(callback_query_id: cb_id, text: 'Вызываем...')
  rescue Telephony::Error => e
    bot_client.answer_callback_query(callback_query_id: cb_id, text: e.message.to_s.truncate(150), show_alert: true)
  end

  def process_leg_callback_action(cb_id:, tg_user_id:, action:, leg_id:)
    leg = TelegramCalls::Registry.fetch_leg(leg_id)
    unless authorized_leg_operator?(leg, tg_user_id)
      return bot_client.answer_callback_query(callback_query_id: cb_id, text: 'Вызов недоступен', show_alert: true)
    end

    execute_leg_termination!(action: action, leg: leg)
    bot_client.answer_callback_query(callback_query_id: cb_id, text: action == 'reject' ? 'Вызов отклонён' : 'Звонок завершён')
  end

  def execute_leg_termination!(action:, leg:)
    label = action == 'reject' ? '❌ Вызов отклонён' : '✅ <b>Звонок завершён</b>'
    term = TelegramCalls::LegCanceller.cancel_single_leg!(leg_id: leg['leg_id'], status_text: label, decline_sip: action == 'reject')
    return unless leg['claimed'] || leg['source_type'] == 'telephony_sip_outbound'

    end_payload = (term.is_a?(Hash) ? term : {}).merge('leg_id' => leg['leg_id'], 'force_finalize' => true)
    TelegramCalls::LegEndProcessor.new(leg: leg, payload: end_payload).perform
  end

  def authorized_leg_operator?(leg, tg_user_id)
    leg.present? && Telephony::TelegramOperatorBinding.connected.exists?(
      id: leg['binding_id'], user_id: leg['user_id'], telegram_user_id: tg_user_id
    )
  end

  def connected_bindings(tg_user_id)
    Telephony::TelegramOperatorBinding.connected.includes(:account, :user).where(telegram_user_id: tg_user_id).to_a
  end

  def reply_unlinked(chat_id)
    bot_client.send_message(chat_id: chat_id, text: '🔗 Ваш Telegram не привязан. Откройте OneLink → Телефон → «Подключить Telegram».')
  end
end
