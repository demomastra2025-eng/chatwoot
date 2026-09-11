# frozen_string_literal: true

class CommunicationThreads::RealtimeUpdateService
  EVENT_NAME = 'communication_thread.updated'
  FEATURE_NAME = 'communication_threads'

  def initialize(communication_thread_id:, source_conversation_id:, source_event:, message_id: nil, performer_id: nil)
    @communication_thread_id = communication_thread_id
    @source_conversation_id = source_conversation_id
    @source_event = source_event
    @message_id = message_id
    @performer_id = performer_id
  end

  def perform
    communication_thread = CommunicationThread.find(communication_thread_id)
    return unless communication_thread.account.feature_enabled?(FEATURE_NAME)

    source_conversation = communication_thread.conversations.find(source_conversation_id)

    message = source_message(source_conversation)

    links = communication_thread.communication_thread_conversations.includes(
      :conversation,
      { contact_inbox: :channel_profile },
      inbox: [:members, :channel]
    ).to_a
    broadcast_dashboard_updates(communication_thread, links, source_conversation, message)
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound => e
    Rails.logger.warn(
      "[CommunicationThreads] realtime refresh retryable failure thread=#{communication_thread_id} " \
      "conversation=#{source_conversation_id}: #{e.class}: #{e.message}"
    )
    raise
  end

  private

  attr_reader :communication_thread_id, :source_conversation_id, :source_event, :message_id, :performer_id

  def source_message(source_conversation)
    return if message_id.blank?

    source_conversation.messages.find(message_id)
  end

  def broadcast_dashboard_updates(communication_thread, links, source_conversation, message)
    account = communication_thread.account
    members_by_payload = Hash.new { |hash, key| hash[key] = [] }
    groups = recipient_groups(account, links, source_conversation)
    read_states = batch_read_states(account, links, groups)
    groups.each_value do |group|
      shared_payload = shared_realtime_payload(communication_thread, group[:links], source_conversation, message)
      group[:users].each do |user|
        payload = realtime_payload(communication_thread, group[:links], shared_payload, user, read_states)
        members_by_payload[payload] << user.pubsub_token
      end
    end

    members_by_payload.each { |payload, members| broadcast(account, members, payload) }
  end

  def recipient_groups(account, links, source_conversation)
    CommunicationThreads::RealtimeRecipientGroups.new(
      account: account,
      links: links,
      source_conversation: source_conversation
    ).perform
  end

  def batch_read_states(account, links, groups)
    Conversations::UserReadStateBatchPreloader.new(
      account: account,
      conversation_ids: links.map(&:conversation_id),
      users: groups.values.flat_map { |group| group[:users] }.uniq
    ).perform
  end

  def shared_realtime_payload(communication_thread, links, source_conversation, message)
    payload = thread_identity_payload(communication_thread, links, source_conversation)
              .merge(thread_invariant_state_payload(communication_thread, links))
              .merge(thread_timing_payload(communication_thread, links))
    payload[:message_id] = message&.id
    payload[:message] = message_payload(message, communication_thread) if message.present?
    payload
  end

  def realtime_payload(communication_thread, links, shared_payload, user, read_states)
    channels = channel_payloads(communication_thread, links, user, read_states)
    shared_payload.merge(user_thread_state_payload(channels))
  end

  def thread_identity_payload(communication_thread, links, source_conversation)
    {
      id: communication_thread.display_id,
      communication_thread_id: communication_thread.display_id,
      is_communication_thread: true,
      meta: thread_meta(communication_thread, source_conversation),
      source_event: source_event,
      conversation_id: source_conversation.display_id,
      conversation_ids: links.map { |link| link.conversation.display_id },
      contact_id: communication_thread.contact_id,
      inbox_id: source_conversation.inbox_id,
      inbox_name: source_conversation.inbox&.name,
      contact_inbox_id: source_conversation.contact_inbox_id,
      channel: source_conversation.inbox&.channel_type,
      medium: thread_medium(source_conversation.inbox)
    }
  end

  def thread_invariant_state_payload(communication_thread, links)
    {
      status: communication_thread.status,
      priority: communication_thread.priority,
      assignee_id: communication_thread.assignee_id,
      team_id: communication_thread.team_id,
      labels: label_list(links),
      scheduling_appointment_statuses: scheduling_appointment_statuses(communication_thread)
    }
  end

  def user_thread_state_payload(channels)
    {
      channels: channels,
      can_reply: channels.any? { |channel| channel_replyable?(channel) },
      unread_count: channels.sum { |channel| channel[:unread_count].to_i }
    }
  end

  def thread_timing_payload(communication_thread, links)
    timestamps = directional_message_timestamps(communication_thread, links)
    {
      last_activity_at: communication_thread.last_activity_at.to_i,
      last_incoming_message_at: timestamps[:incoming]&.to_i,
      last_outgoing_message_at: timestamps[:outgoing]&.to_i,
      timestamp: communication_thread.last_activity_at.to_i,
      updated_at: communication_thread.updated_at.to_f
    }
  end

  def message_payload(message, communication_thread)
    message.push_event_data.merge(communication_thread_id: communication_thread.display_id)
  end

  def thread_medium(inbox)
    inbox&.channel.respond_to?(:medium) ? inbox.channel.medium : nil
  end

  def thread_meta(communication_thread, source_conversation)
    {
      sender: communication_thread.contact.push_event_data(contact_inbox: source_conversation.contact_inbox),
      channel: 'CommunicationThread',
      assignee: communication_thread.assignee&.push_event_data,
      assignee_type: communication_thread.assignee.present? ? 'User' : nil,
      team: communication_thread.team&.push_event_data
    }
  end

  def channel_payloads(communication_thread, links, user, read_states)
    CommunicationThreads::ChannelCapabilitiesBuilder.new(
      links: links,
      contact: communication_thread.contact,
      deduplicate_linked: false,
      unread_counts: read_states.unread_counts_for(user),
      last_seen_timestamps: read_states.last_seen_timestamps_for(user)
    ).perform
  end

  def directional_message_timestamps(communication_thread, links)
    Conversations::DirectionalMessageTimestampPreloader
      .new(account: communication_thread.account)
      .for_communication_threads(communication_thread.id => links)
      .fetch(communication_thread.id, {})
  end

  def scheduling_appointment_statuses(communication_thread)
    Scheduling::AppointmentDialogStatusContextBuilder
      .new(account: communication_thread.account)
      .for_communication_threads([communication_thread])
      .fetch(communication_thread.id, [])
  end

  def channel_replyable?(channel)
    channel[:can_reply] || channel[:can_send_text] || channel[:requires_template] ||
      (channel[:channel] == 'Channel::Voice' && !channel[:disabled])
  end

  def label_list(links)
    links.flat_map { |link| link.conversation&.label_list }.compact.uniq
  end

  def broadcast(account, members, data)
    payload = data.merge(account_id: account.id)
    payload[:performer] = performer(account).push_event_data if performer(account).present?

    ActionCableBroadcastJob.perform_later(members.uniq, EVENT_NAME, payload)
  end

  def performer(account)
    return @performer if defined?(@performer)

    @performer = account.users.find_by(id: performer_id)
  end
end
