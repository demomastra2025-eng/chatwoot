class TelegramCalls::BotClient
  API_BASE = 'https://api.telegram.org'.freeze
  REQUEST_TIMEOUT = 8

  ON_LINE_BUTTON = '🟢 Выйти на линию'.freeze
  OFF_LINE_BUTTON = '🔴 Сойти с линии'.freeze
  STATUS_BUTTON = '📊 Статус'.freeze
  SHARE_PHONE_BUTTON = '📱 Отправить мой номер для звонков'.freeze

  def initialize(bot_token: TelegramCalls::Config.bot_token)
    @bot_token = bot_token.to_s.strip
  end

  def configured?
    @bot_token.present?
  end

  def send_message(chat_id:, text:, reply_markup: nil, parse_mode: 'HTML')
    return nil unless configured? && chat_id.present? && text.present?

    body = { chat_id: chat_id.to_s, text: text, parse_mode: parse_mode, disable_web_page_preview: true }
    body[:reply_markup] = reply_markup if reply_markup.present?
    post_telegram('sendMessage', body)
  end

  def edit_message_text(chat_id:, message_id:, text:, reply_markup: nil, parse_mode: 'HTML')
    return nil unless configured? && chat_id.present? && message_id.present? && text.present?

    body = {
      chat_id: chat_id.to_s,
      message_id: message_id.to_i,
      text: text,
      parse_mode: parse_mode,
      disable_web_page_preview: true
    }
    body[:reply_markup] = reply_markup unless reply_markup.nil?
    post_telegram('editMessageText', body)
  end

  def answer_callback_query(callback_query_id:, text: nil, show_alert: false)
    return nil unless configured? && callback_query_id.present?

    body = { callback_query_id: callback_query_id.to_s, show_alert: show_alert }
    body[:text] = text if text.present?
    post_telegram('answerCallbackQuery', body)
  end

  def self.operator_reply_keyboard(on_line:, needs_phone: false)
    toggle_text = on_line ? OFF_LINE_BUTTON : ON_LINE_BUTTON
    rows = [[{ text: toggle_text }, { text: STATUS_BUTTON }]]
    rows << [{ text: SHARE_PHONE_BUTTON, request_contact: true }] if needs_phone
    { keyboard: rows, resize_keyboard: true, is_persistent: true }
  end

  def self.call_inline_keyboard(leg_id:, conversation_url: nil, state: :ringing)
    rows = []
    if state == :ringing && leg_id.present?
      rows << [{ text: '❌ Отклонить', callback_data: "reject:#{leg_id}" }]
    elsif state == :active && leg_id.present?
      rows << [{ text: '🔚 Завершить звонок', callback_data: "hangup:#{leg_id}" }]
    end
    rows << [{ text: '💬 Открыть диалог в OneLink', url: conversation_url }] if conversation_url.present?
    rows.present? ? { inline_keyboard: rows } : { inline_keyboard: [] }
  end

  private

  def post_telegram(method_name, body)
    response = HTTParty.post(
      "#{API_BASE}/bot#{@bot_token}/#{method_name}",
      headers: { 'Content-Type' => 'application/json' },
      body: body.to_json,
      timeout: REQUEST_TIMEOUT
    )
    parsed = response.parsed_response
    return parsed['result'] if response.success? && parsed.is_a?(Hash) && parsed['ok']

    log_failure(method_name, response.code, parsed)
    nil
  rescue StandardError => e
    Rails.logger.warn("TELEGRAM_CALLS_BOT_CLIENT_ERROR method=#{method_name} error=#{e.class}: #{e.message}")
    nil
  end

  def log_failure(method_name, status_code, parsed)
    desc = parsed.is_a?(Hash) ? parsed['description'] : nil
    Rails.logger.warn("TELEGRAM_CALLS_BOT_API_FAILED method=#{method_name} status=#{status_code} desc=#{desc}")
  end
end
