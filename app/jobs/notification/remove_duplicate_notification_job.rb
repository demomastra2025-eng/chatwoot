class Notification::RemoveDuplicateNotificationJob < ApplicationJob
  queue_as :default

  def perform(notification)
    return unless notification.is_a?(Notification)

    # Conversation, CRM task/deal and appointment ids are separate sequences:
    # a duplicate is an older notification of the same user and the same
    # primary actor (type and id together).
    duplicate_notifications = Notification.where(
      user_id: notification.user_id,
      primary_actor_type: notification.primary_actor_type,
      primary_actor_id: notification.primary_actor_id
    ).order(created_at: :desc)

    # Skip the first one (the latest notification) and destroy the rest
    duplicate_notifications.offset(1).each(&:destroy)
  end
end
