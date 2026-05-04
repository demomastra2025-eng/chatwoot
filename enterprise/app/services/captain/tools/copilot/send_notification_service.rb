class Captain::Tools::Copilot::SendNotificationService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'send_notification'
  end

  description 'Send an in-app notification to an account user about the current or specified conversation'
  param :message, type: :string, desc: 'Notification body to show to the teammate', required: true
  param :title, type: :string, desc: 'Optional notification title. Defaults to Captain notification', required: false
  param :recipient_type, type: :string, desc: 'Recipient type. MVP supports user only', required: false
  param :recipient_id, type: :number, desc: 'Recipient user ID in this account', required: false
  param :recipient_email, type: :string, desc: 'Recipient user email in this account', required: false
  param :recipient_name, type: :string, desc: 'Recipient exact user name in this account. Use ID or email if names are ambiguous', required: false
  param :conversation_id, type: :number, desc: 'Conversation ID or display ID. Defaults to the current conversation', required: false

  def execute(
    message:,
    title: nil,
    recipient_type: nil,
    recipient_id: nil,
    recipient_email: nil,
    recipient_name: nil,
    conversation_id: nil
  )
    notification = notification_operations.send_notification(
      message: message,
      title: title,
      recipient_type: recipient_type,
      recipient_id: recipient_id,
      recipient_email: recipient_email,
      recipient_name: recipient_name,
      conversation_id: conversation_id
    )

    formatted_payload(
      action: 'send_notification',
      notification: notification_payload(notification)
    )
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    user_has_permission('conversation_manage') || user_has_permission('conversation_unassigned_manage') || user_has_permission('conversation_participating_manage')
  end

  private

  def notification_operations
    Captain::Tools::Operations::NotificationOperations.new(
      assistant: assistant,
      conversation: current_conversation,
      actor: @user
    )
  end

  def notification_payload(notification)
    meta = notification.meta.to_h.with_indifferent_access
    captain_meta = meta[:captain_notification] || {}

    {
      id: notification.id,
      notification_type: notification.notification_type,
      recipient: {
        id: notification.user_id,
        name: notification.user&.name,
        email: notification.user&.email
      }.compact,
      title: notification.push_message_title,
      message: notification.push_message_body,
      conversation_id: notification.primary_actor_id,
      conversation_display_id: notification.conversation_display_id,
      assistant_id: captain_meta[:assistant_id],
      created_at: notification.created_at&.iso8601
    }.compact
  end
end
