# frozen_string_literal: true

class Notification::TelegramNotificationJob < ApplicationJob
  queue_as :default

  def perform(notification)
    Notification::TelegramNotificationService.new(notification: notification).perform
  end
end
