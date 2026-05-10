# frozen_string_literal: true

class Webhooks::TelegramNotificationsController < ActionController::API
  def process_payload
    return head :not_found unless valid_webhook_secret?

    message = telegram_message
    return head :ok if message.blank?

    profile_token = extract_profile_token(message[:text])
    if profile_token.blank?
      send_reply(message, 'Отправьте токен доступа из профиля OneLink.')
      return head :ok
    end

    user = TelegramNotificationBinding.find_user_by_profile_token(profile_token)
    if user.blank?
      send_reply(message, 'Токен доступа не найден. Скопируйте актуальный токен из профиля OneLink и отправьте его боту.')
      return head :ok
    end

    TelegramNotificationBinding.verify_user_from_telegram!(user, message)
    send_reply(message, 'Готово: Telegram привязан к вашему профилю OneLink. Теперь можно включить Telegram-уведомления.')
    head :ok
  rescue ActiveRecord::RecordInvalid
    send_reply(message, 'Этот Telegram уже привязан к другому профилю OneLink.')
    head :ok
  end

  private

  def valid_webhook_secret?
    expected_secret = ENV.fetch('TELEGRAM_NOTIFICATION_WEBHOOK_SECRET', nil).to_s
    supplied_secret = params[:webhook_secret].to_s

    expected_secret.present? && supplied_secret.bytesize == expected_secret.bytesize &&
      ActiveSupport::SecurityUtils.secure_compare(supplied_secret, expected_secret)
  end

  def telegram_message
    payload = params[:message] || params[:edited_message]
    payload.respond_to?(:to_unsafe_h) ? payload.to_unsafe_h.deep_symbolize_keys : payload.to_h.deep_symbolize_keys
  end

  def extract_profile_token(text)
    return if text.blank?

    normalized_text = text.to_s.strip
    start_payload = normalized_text.match(%r{\A/start(?:\s+(.+))?\z})&.[](1)
    (start_payload || normalized_text).strip.presence
  end

  def send_reply(message, text)
    chat_id = message.dig(:chat, :id)
    return if chat_id.blank?

    TelegramNotification::BotClient.send_message(chat_id: chat_id, text: text)
  end
end
