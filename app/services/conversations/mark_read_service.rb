class Conversations::MarkReadService
  def initialize(conversation:, user:, refresh_communication_thread: true)
    @conversation = conversation
    @user = user
    @refresh_communication_thread = refresh_communication_thread
  end

  def perform
    user_unread_messages = @conversation.unread_messages_for(@user)
    if user_unread_messages.exists?
      sync_payload = unread_message_sync_payload(user_unread_messages)
      update_last_seen(Time.current.utc)
      sync_mark_read_receipts(sync_payload)
      return
    end

    return unless should_update_last_seen?

    update_last_seen(Time.current.utc)
  end

  private

  def update_last_seen(last_seen_at)
    Conversations::RecordUserReadStateService.new(conversation: @conversation, user: @user).perform(last_seen_at: last_seen_at)
    last_seen_updater.perform(
      last_seen_at: last_seen_at,
      update_assignee: assignee?,
      refresh_communication_thread: @refresh_communication_thread
    )
  end

  def should_update_last_seen?
    user_last_seen_at = @conversation.last_seen_at_for(@user)
    user_needs_update = user_last_seen_at.blank? || user_last_seen_at < 1.hour.ago
    return user_needs_update unless assignee?

    assignee_needs_update = @conversation.assignee_last_seen_at.blank? || @conversation.assignee_last_seen_at < 1.hour.ago
    user_needs_update || assignee_needs_update
  end

  def unread_message_sync_payload(user_unread_messages)
    channel = @conversation.inbox.channel

    case channel
    when Channel::WhatsappWeb
      { whatsapp_web_messages: unread_incoming_messages_for_sync(user_unread_messages, :source_id) }
    when Channel::Whatsapp
      return {} unless channel.provider == 'whatsapp_cloud'

      { whatsapp_cloud_messages: unread_incoming_messages_for_sync(user_unread_messages, :source_id, :created_at, :content_attributes) }
    when Channel::Telegram
      return {} if @conversation.additional_attributes['business_connection_id'].blank?

      { telegram_messages: unread_incoming_messages_for_sync(user_unread_messages, :source_id) }
    when Channel::TelegramPersonal
      { telegram_personal_messages: unread_incoming_messages_for_sync(user_unread_messages, :source_id, :content_attributes) }
    else
      {}
    end
  end

  def unread_incoming_messages_for_sync(user_unread_messages, *columns)
    user_unread_messages.where(account_id: @conversation.account_id)
                        .incoming
                        .where.not(source_id: [nil, ''])
                        .select(:id, *columns)
                        .to_a
  end

  def sync_mark_read_receipts(sync_payload)
    sync_whatsapp_web_messages_read!(sync_payload[:whatsapp_web_messages])
    sync_whatsapp_cloud_messages_read!(sync_payload[:whatsapp_cloud_messages])
    sync_telegram_messages_read!(sync_payload[:telegram_messages])
    sync_telegram_personal_messages_read!(sync_payload[:telegram_personal_messages])
  end

  def sync_whatsapp_web_messages_read!(messages)
    return if messages.blank?

    WhatsappWeb::MarkMessagesReadService.new(
      conversation: @conversation,
      messages: messages
    ).perform
  end

  def sync_whatsapp_cloud_messages_read!(messages)
    return if messages.blank?

    Whatsapp::MarkMessagesReadService.new(
      conversation: @conversation,
      messages: messages
    ).perform
  end

  def sync_telegram_messages_read!(messages)
    return if messages.blank?

    Telegram::MarkMessagesReadService.new(
      conversation: @conversation,
      messages: messages
    ).perform
  end

  def sync_telegram_personal_messages_read!(messages)
    return if messages.blank?

    TelegramPersonal::MarkMessagesReadService.new(
      conversation: @conversation,
      messages: messages
    ).perform
  end

  def assignee?
    @conversation.assignee_id? && @user == @conversation.assignee
  end

  def last_seen_updater
    @last_seen_updater ||= Conversations::LastSeenUpdater.new(conversation: @conversation)
  end
end
