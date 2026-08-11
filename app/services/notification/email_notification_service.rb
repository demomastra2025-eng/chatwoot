class Notification::EmailNotificationService
  pattr_initialize [:notification!]

  def perform
    # don't send emails if user read the push notification already
    return if notification.read_at.present?
    # don't send emails if user is not confirmed
    return if notification.user.confirmed_at.nil?
    return unless user_subscribed_to_notification?
    return unless notification.account.within_email_rate_limit?
    return if imported_history_notification?

    send_notification_email
    notification.account.increment_email_sent_count
  end

  private

  # TODO : Clean up whatever happening over here
  # Segregate the mailers properly
  def send_notification_email
    return if notification.primary_actor.blank?
    return if secondary_actor_required? && notification.secondary_actor.blank?

    AgentNotifications::ConversationNotificationsMailer.with(account: notification.account).public_send(
      notification.notification_type.to_s, notification.primary_actor, notification.user, notification.secondary_actor
    ).deliver_later
  end

  def user_subscribed_to_notification?
    notification_setting = notification.user.notification_settings.find_by(account_id: notification.account.id)
    return true if notification_setting.public_send("email_#{notification.notification_type}?")

    false
  end

  def secondary_actor_required?
    %w[conversation_mention assigned_conversation_new_message participating_conversation_new_message].include?(
      notification.notification_type
    )
  end

  def imported_history_notification?
    imported_history_message?(notification.secondary_actor) || imported_history_conversation?(notification.primary_actor)
  end

  def imported_history_conversation?(actor)
    return false unless actor.is_a?(Conversation)

    message = actor.messages.where.not(message_type: :activity).reorder(created_at: :desc, id: :desc).first
    imported_history_message?(message)
  end

  def imported_history_message?(actor)
    actor.is_a?(Message) && !!ActiveModel::Type::Boolean.new.cast(actor.content_attributes.to_h['imported_history'])
  end
end
