class ActionCableListener < BaseListener
  include Events::Types

  COMMUNICATION_THREAD_FEATURE = 'communication_threads'.freeze

  def notification_created(event)
    notification, account, unread_count, count = extract_notification_and_account(event)
    tokens = [event.data[:notification].user.pubsub_token]
    broadcast(account, tokens, NOTIFICATION_CREATED, { notification: notification.push_event_data, unread_count: unread_count, count: count })
  end

  def notification_updated(event)
    notification, account, unread_count, count = extract_notification_and_account(event)
    tokens = [event.data[:notification].user.pubsub_token]
    broadcast(account, tokens, NOTIFICATION_UPDATED, { notification: notification.push_event_data, unread_count: unread_count, count: count })
  end

  def notification_deleted(event)
    notification_data = event.data[:notification_data]

    user = User.find_by(id: notification_data[:user_id])
    account = Account.find_by(id: notification_data[:account_id])
    return if user.blank? || account.blank?

    notification_finder = NotificationFinder.new(user, account)
    tokens = [user.pubsub_token]
    broadcast(account, tokens, NOTIFICATION_DELETED, {
                notification: { id: notification_data[:id] },
                unread_count: notification_finder.unread_count,
                count: notification_finder.count
              })
  end

  def account_cache_invalidated(event)
    account = event.data[:account]
    tokens = user_tokens(account, account.agents)

    broadcast(account, tokens, ACCOUNT_CACHE_INVALIDATED, {
                cache_keys: event.data[:cache_keys]
              })
  end

  def message_created(event)
    message, account = extract_message_and_account(event)
    conversation = message.conversation
    dashboard_tokens = user_tokens(account, conversation.inbox.members)
    customer_tokens = contact_tokens(conversation.contact_inbox, message)

    broadcast(account, dashboard_tokens, MESSAGE_CREATED, message.push_event_data)
    broadcast(account, customer_tokens, MESSAGE_CREATED, message.push_event_data(include_communication_thread: false))
    broadcast_communication_thread_update(conversation, MESSAGE_CREATED, message: message)
  end

  def message_updated(event)
    message, account = extract_message_and_account(event)
    conversation = message.conversation
    dashboard_tokens = user_tokens(account, conversation.inbox.members)
    customer_tokens = contact_tokens(conversation.contact_inbox, message)

    broadcast(account, dashboard_tokens, MESSAGE_UPDATED, message.push_event_data.merge(previous_changes: event.data[:previous_changes]))
    broadcast(
      account,
      customer_tokens,
      MESSAGE_UPDATED,
      message.push_event_data(include_communication_thread: false).merge(previous_changes: event.data[:previous_changes])
    )
    broadcast_communication_thread_update(conversation, MESSAGE_UPDATED, message: message)
  end

  def first_reply_created(event)
    message, account = extract_message_and_account(event)
    conversation = message.conversation
    tokens = user_tokens(account, conversation.inbox.members)

    broadcast(account, tokens, FIRST_REPLY_CREATED, message.push_event_data)
    broadcast_communication_thread_update(conversation, FIRST_REPLY_CREATED, message: message)
  end

  def conversation_created(event)
    conversation, account = extract_conversation_and_account(event)
    tokens = user_tokens(account, conversation.inbox.members) + contact_inbox_tokens(conversation.contact_inbox)

    broadcast(account, tokens, CONVERSATION_CREATED, conversation.push_event_data)
  end

  def conversation_read(event)
    conversation, account = extract_conversation_and_account(event)
    tokens = user_tokens(account, conversation.inbox.members)

    broadcast(account, tokens, CONVERSATION_READ, conversation.push_event_data)
    broadcast_communication_thread_update(conversation, CONVERSATION_READ)
  end

  def conversation_status_changed(event)
    conversation, account = extract_conversation_and_account(event)
    tokens = user_tokens(account, conversation.inbox.members) + contact_inbox_tokens(conversation.contact_inbox)

    broadcast(account, tokens, CONVERSATION_STATUS_CHANGED, conversation.push_event_data)
    broadcast_communication_thread_update(conversation, CONVERSATION_STATUS_CHANGED)
  end

  def conversation_updated(event)
    conversation, account = extract_conversation_and_account(event)
    tokens = user_tokens(account, conversation.inbox.members) + contact_inbox_tokens(conversation.contact_inbox)

    broadcast(account, tokens, CONVERSATION_UPDATED, conversation.push_event_data)
    broadcast_communication_thread_update(conversation, CONVERSATION_UPDATED)
  end

  def conversation_typing_on(event)
    conversation = event.data[:conversation]
    account = conversation.account
    user = event.data[:user]
    tokens = typing_event_listener_tokens(account, conversation, user)

    broadcast(
      account,
      tokens,
      CONVERSATION_TYPING_ON,
      conversation: conversation.push_event_data,
      user: user.push_event_data,
      is_private: event.data[:is_private] || false
    )
  end

  def conversation_typing_off(event)
    conversation = event.data[:conversation]
    account = conversation.account
    user = event.data[:user]
    tokens = typing_event_listener_tokens(account, conversation, user)

    broadcast(
      account,
      tokens,
      CONVERSATION_TYPING_OFF,
      conversation: conversation.push_event_data,
      user: user.push_event_data,
      is_private: event.data[:is_private] || false
    )
  end

  def assignee_changed(event)
    conversation, account = extract_conversation_and_account(event)
    tokens = user_tokens(account, conversation.inbox.members)

    broadcast(account, tokens, ASSIGNEE_CHANGED, conversation.push_event_data)
    broadcast_communication_thread_update(conversation, ASSIGNEE_CHANGED)
  end

  def team_changed(event)
    conversation, account = extract_conversation_and_account(event)
    tokens = user_tokens(account, conversation.inbox.members)

    broadcast(account, tokens, TEAM_CHANGED, conversation.push_event_data)
    broadcast_communication_thread_update(conversation, TEAM_CHANGED)
  end

  def conversation_contact_changed(event)
    conversation, account = extract_conversation_and_account(event)
    tokens = user_tokens(account, conversation.inbox.members)

    broadcast(account, tokens, CONVERSATION_CONTACT_CHANGED, conversation.push_event_data)
  end

  def contact_created(event)
    contact, account = extract_contact_and_account(event)
    broadcast(account, [account_token(account)], CONTACT_CREATED, contact.push_event_data)
  end

  def contact_updated(event)
    contact, account = extract_contact_and_account(event)
    broadcast(account, [account_token(account)], CONTACT_UPDATED, contact.push_event_data)
  end

  def contact_merged(event)
    contact, account = extract_contact_and_account(event)
    broadcast(account, [account_token(account)], CONTACT_MERGED, contact.push_event_data)
  end

  def contact_deleted(event)
    contact_data = event.data[:contact_data]
    account = Account.find_by(id: contact_data[:account_id])
    return if account.blank?

    broadcast(account, [account_token(account)], CONTACT_DELETED, contact_data)
  end

  def crm_deal_created(event)
    broadcast_crm_deal_event(event, CRM_DEAL_CREATED)
  end

  def crm_deal_updated(event)
    broadcast_crm_deal_event(event, CRM_DEAL_UPDATED)
  end

  def crm_deal_stage_changed(event)
    broadcast_crm_deal_event(event, CRM_DEAL_STAGE_CHANGED)
  end

  def crm_deal_archived(event)
    broadcast_crm_deal_event(event, CRM_DEAL_ARCHIVED)
  end

  def crm_deal_unarchived(event)
    broadcast_crm_deal_event(event, CRM_DEAL_UNARCHIVED)
  end

  def conversation_mentioned(event)
    conversation, account = extract_conversation_and_account(event)
    user = event.data[:user]

    broadcast(account, [user.pubsub_token], CONVERSATION_MENTIONED, conversation.push_event_data)
  end

  private

  def account_token(account)
    "account_#{account.id}"
  end

  def broadcast_communication_thread_update(conversation, source_event, message: nil)
    account = conversation&.account
    return unless account&.feature_enabled?(COMMUNICATION_THREAD_FEATURE)

    communication_thread = conversation.communication_thread || conversation.refresh_communication_thread!
    return if communication_thread.blank?

    communication_thread.reload
    links = communication_thread.communication_thread_conversations.includes(:conversation, inbox: [:members, :channel]).to_a
    broadcast_communication_thread_dashboard_updates(account, communication_thread, links, conversation, source_event, message)
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound => e
    Rails.logger.warn("[CommunicationThreads] realtime refresh skipped conversation=#{conversation&.id}: #{e.class}: #{e.message}")
  end

  def broadcast_communication_thread_dashboard_updates(account, communication_thread, links, source_conversation, source_event, message)
    communication_thread_dashboard_users(account, links).each do |user|
      visible_links = communication_thread_visible_links_for(account, user, links)
      next if visible_links.blank?
      next unless visible_links.any? { |link| link.conversation_id == source_conversation.id }

      payload = communication_thread_realtime_payload(communication_thread, visible_links, source_conversation, source_event, message)
      broadcast(account, [user.pubsub_token], COMMUNICATION_THREAD_UPDATED, payload)
    end
  end

  def communication_thread_dashboard_users(account, links)
    users = links.flat_map { |link| link.inbox.members.to_a } + account.administrators.to_a
    users.index_by(&:id).values
  end

  def communication_thread_visible_links_for(account, user, links)
    accessible_conversation_ids = Conversations::PermissionFilterService.new(
      account.conversations.where(id: links.map(&:conversation_id)),
      user,
      account
    ).perform.pluck(:id)

    links.select { |link| accessible_conversation_ids.include?(link.conversation_id) }
  end

  def communication_thread_realtime_payload(communication_thread, links, source_conversation, source_event, message)
    {
      id: communication_thread.display_id,
      communication_thread_id: communication_thread.display_id,
      is_communication_thread: true,
      source_event: source_event,
      message_id: message&.id,
      conversation_id: source_conversation.display_id,
      conversation_ids: links.map { |link| link.conversation.display_id },
      contact_id: communication_thread.contact_id,
      inbox_id: source_conversation.inbox_id,
      inbox_name: source_conversation.inbox&.name,
      contact_inbox_id: source_conversation.contact_inbox_id,
      channel: source_conversation.inbox&.channel_type,
      medium: communication_thread_medium(source_conversation.inbox),
      status: communication_thread.status,
      priority: communication_thread.priority,
      assignee_id: communication_thread.assignee_id,
      team_id: communication_thread.team_id,
      unread_count: communication_thread.unread_count,
      last_activity_at: communication_thread.last_activity_at.to_i,
      timestamp: communication_thread.last_activity_at.to_i,
      updated_at: communication_thread.updated_at.to_f
    }
  end

  def communication_thread_medium(inbox)
    inbox&.channel.respond_to?(:medium) ? inbox.channel.medium : nil
  end

  def typing_event_listener_tokens(account, conversation, user)
    current_user_token = if user.is_a?(Contact)
                           conversation.contact_inbox.pubsub_token
                         elsif user.respond_to?(:pubsub_token)
                           user.pubsub_token
                         end

    tokens = user_tokens(account, conversation.inbox.members) + [conversation.contact_inbox.pubsub_token]
    current_user_token.present? ? tokens - [current_user_token] : tokens
  end

  def user_tokens(account, agents)
    agent_tokens = agents.pluck(:pubsub_token)
    admin_tokens = account.administrators.pluck(:pubsub_token)
    (agent_tokens + admin_tokens).uniq
  end

  def contact_tokens(contact_inbox, message)
    return [] if message.private?
    return [] if message.activity?
    return [] if contact_inbox.nil?

    contact_inbox_tokens(contact_inbox)
  end

  def contact_inbox_tokens(contact_inbox)
    contact = contact_inbox.contact

    contact_inbox.hmac_verified? ? contact.contact_inboxes.where(hmac_verified: true).filter_map(&:pubsub_token) : [contact_inbox.pubsub_token]
  end

  def broadcast_crm_deal_event(event, event_name)
    deal = event.data[:deal]
    account = event.data[:account] || deal&.account
    return if account.blank? || deal.blank?

    broadcast(
      account,
      [account_token(account)],
      event_name,
      {
        deal: ::Crm::PayloadBuilder.deal(deal),
        meta: event.data[:meta] || {}
      }
    )
  end

  def broadcast(account, tokens, event_name, data)
    return if tokens.blank?

    payload = data.merge(account_id: account.id)
    # So the frondend knows who performed the action.
    # Useful in cases like conversation assignment for generating a notification with assigner name.
    payload[:performer] = Current.user&.push_event_data if Current.user.present?

    ::ActionCableBroadcastJob.perform_later(tokens.uniq, event_name, payload)
  end
end

ActionCableListener.prepend_mod_with('ActionCableListener')
