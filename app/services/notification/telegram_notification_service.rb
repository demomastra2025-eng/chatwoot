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
    case notification.primary_actor
    when Conversation
      app_account_conversation_url(account_id: notification.account_id, id: notification.conversation_display_id)
    when Crm::Task
      frontend_url("/app/accounts/#{notification.account_id}/crm/tasks?taskId=#{notification.primary_actor.id}")
    when Crm::Deal
      frontend_url("/app/accounts/#{notification.account_id}/crm/deals?dealId=#{notification.primary_actor.id}")
    when Scheduling::Appointment
      frontend_url("/app/accounts/#{notification.account_id}/scheduling/calendar?appointmentId=#{notification.primary_actor.id}")
    end
  end

  def frontend_url(path)
    base_url = ENV.fetch('FRONTEND_URL', nil).presence || ENV.fetch('INSTALLATION_URL', nil).presence
    return path if base_url.blank?

    "#{base_url}#{path}"
  end
end
