# frozen_string_literal: true

class Notification::TelegramNotificationService
  include Rails.application.routes.url_helpers

  pattr_initialize [:notification!]

  def perform
    return unless user_subscribed_to_notification?
    return unless binding&.connected?
    return unless TelegramNotification::BotClient.configured?

    TelegramNotification::BotClient.send_message(chat_id: binding.telegram_chat_id, text: message_text)
  rescue StandardError => e
    Rails.logger.error("Telegram notification delivery failed for user_id=#{user.id}: #{e.class}")
  end

  private

  delegate :user, to: :notification

  def binding
    @binding ||= user.telegram_notification_binding
  end

  def user_subscribed_to_notification?
    notification_setting = user.notification_settings.find_by(account_id: notification.account.id)
    return false if notification_setting.blank?

    notification_setting.public_send("telegram_#{notification.notification_type}?")
  end

  def message_text
    [notification.push_message_title, notification.push_message_body, push_url].compact_blank.join("\n")
  end

  def push_url
    app_account_conversation_url(account_id: notification.account_id, id: notification.conversation_display_id)
  end
end
