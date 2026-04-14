class Conversations::MarkReadService
  def initialize(conversation:, user:)
    @conversation = conversation
    @user = user
  end

  def perform
    whatsapp_web_messages = unread_incoming_messages_for_whatsapp_web_sync
    telegram_messages = unread_incoming_messages_for_telegram_sync
    telegram_personal_messages = unread_incoming_messages_for_telegram_personal_sync

    if assignee? && @conversation.assignee_unread_messages.any?
      update_last_seen_on_conversation(Time.current.utc, true)
      sync_whatsapp_web_messages_read!(whatsapp_web_messages)
      sync_telegram_messages_read!(telegram_messages)
      sync_telegram_personal_messages_read!(telegram_personal_messages)
      return
    end

    if !assignee? && @conversation.unread_messages.any?
      update_last_seen_on_conversation(Time.current.utc, false)
      sync_whatsapp_web_messages_read!(whatsapp_web_messages)
      sync_telegram_messages_read!(telegram_messages)
      sync_telegram_personal_messages_read!(telegram_personal_messages)
      return
    end

    return unless should_update_last_seen?

    update_last_seen_on_conversation(Time.current.utc, assignee?)
    sync_whatsapp_web_messages_read!(whatsapp_web_messages)
    sync_telegram_messages_read!(telegram_messages)
    sync_telegram_personal_messages_read!(telegram_personal_messages)
  end

  private

  def update_last_seen_on_conversation(last_seen_at, update_assignee)
    last_seen_updater.perform(last_seen_at: last_seen_at, update_assignee: update_assignee.present?)
  end

  def should_update_last_seen?
    agent_needs_update = @conversation.agent_last_seen_at.blank? || @conversation.agent_last_seen_at < 1.hour.ago
    return agent_needs_update unless assignee?

    assignee_needs_update = @conversation.assignee_last_seen_at.blank? || @conversation.assignee_last_seen_at < 1.hour.ago
    agent_needs_update || assignee_needs_update
  end

  def unread_incoming_messages_for_whatsapp_web_sync
    return [] unless @conversation.inbox.channel.is_a?(Channel::WhatsappWeb)

    @conversation.unread_messages
                 .where(account_id: @conversation.account_id)
                 .incoming
                 .where.not(source_id: [nil, ''])
                 .to_a
  end

  def unread_incoming_messages_for_telegram_sync
    return [] unless @conversation.inbox.channel.is_a?(Channel::Telegram)
    return [] if @conversation.additional_attributes['business_connection_id'].blank?

    @conversation.unread_messages
                 .where(account_id: @conversation.account_id)
                 .incoming
                 .where.not(source_id: [nil, ''])
                 .to_a
  end

  def unread_incoming_messages_for_telegram_personal_sync
    return [] unless @conversation.inbox.channel.is_a?(Channel::TelegramPersonal)

    @conversation.unread_messages
                 .where(account_id: @conversation.account_id)
                 .incoming
                 .where.not(source_id: [nil, ''])
                 .to_a
  end

  def sync_whatsapp_web_messages_read!(messages)
    return if messages.blank?

    WhatsappWeb::MarkMessagesReadService.new(
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
