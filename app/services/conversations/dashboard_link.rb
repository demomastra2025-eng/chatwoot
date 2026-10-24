# frozen_string_literal: true

# The one place that decides where an agent lands when a link to a conversation is opened from outside the dashboard:
# push, email, the Telegram notification bot, Slack, Linear and CRM. When the account has communication threads and the
# conversation belongs to a thread, the link opens the person's dialog; otherwise it opens the plain conversation.
class Conversations::DashboardLink
  FEATURE = 'communication_threads'

  pattr_initialize [:account_id!, :conversation_display_id!, :thread_display_id]

  def self.for(conversation)
    new(
      account_id: conversation.account_id,
      conversation_display_id: conversation.display_id,
      thread_display_id: thread_display_id_for(conversation)
    )
  end

  def self.for_notification(notification)
    new(
      account_id: notification.account_id,
      conversation_display_id: notification.conversation_display_id,
      thread_display_id: notification.communication_thread_display_id
    )
  end

  def self.thread_display_id_for(conversation)
    return unless conversation.account&.feature_enabled?(FEATURE)

    conversation.communication_thread&.display_id
  end

  def thread?
    thread_display_id.present?
  end

  # Path inside the frontend, for callers that prepend FRONTEND_URL themselves (Slack, Linear).
  def path
    return "/app/accounts/#{account_id}/communication_threads/#{thread_display_id}" if thread?

    "/app/accounts/#{account_id}/conversations/#{conversation_display_id}"
  end

  # Full link for callers that include Rails url helpers (mailers, notification and CRM services).
  def url(url_helpers)
    if thread?
      url_helpers.app_account_communication_thread_url(account_id: account_id, id: thread_display_id)
    else
      url_helpers.app_account_conversation_url(account_id: account_id, id: conversation_display_id)
    end
  end
end
