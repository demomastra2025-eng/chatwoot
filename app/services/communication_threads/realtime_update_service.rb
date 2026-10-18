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
    communication_thread = load_communication_thread
    return unless communication_thread.account.feature_enabled?(FEATURE_NAME)

    links = load_links(communication_thread)
    source_conversation = find_source_conversation(communication_thread, links)
    message = source_message(source_conversation)
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

  def load_communication_thread
    CommunicationThread.includes(
      :account, :team, assignee: :avatar_attachment,
                       contact: [:owner, :avatar_attachment, { contact_channel_profiles: :avatar_attachment }]
    ).find(communication_thread_id)
  end

  def load_links(communication_thread)
    links = communication_thread.communication_thread_conversations.includes(
      { conversation: :labels }, { contact_inbox: :channel_profile }, inbox: [:members, :channel]
    ).to_a
    CommunicationThreads::RealtimeRecipientGroups.hydrate_links(links)
  end

  def find_source_conversation(communication_thread, links)
    links.find { |l| l.conversation_id == source_conversation_id }&.conversation ||
      communication_thread.conversations.find(source_conversation_id)
  end

  def source_message(source_conversation)
    source_conversation.messages.find(message_id) if message_id.present?
  end

  def broadcast_dashboard_updates(communication_thread, links, source_conversation, message)
    account = communication_thread.account
    members_by_payload = Hash.new { |hash, key| hash[key] = [] }
    groups = recipient_groups(account, links, source_conversation)
    return if groups.empty?

    read_states = batch_read_states(account, links)
    preload_conversation_directional_timestamps(account, links)
    groups.each_value do |group|
      shared_payload = shared_realtime_payload(communication_thread, group[:links], source_conversation, message)
      payload = realtime_payload(communication_thread, group[:links], shared_payload, read_states)
      group[:users].each { |user| members_by_payload[payload] << user.pubsub_token }
    end

    members_by_payload.each { |payload, members| broadcast(account, members, payload) }
  end

  def recipient_groups(account, links, source_conversation)
    CommunicationThreads::RealtimeRecipientGroups.new(account: account, links: links, source_conversation: source_conversation).perform
  end

  def batch_read_states(account, links)
    Conversations::SharedUnreadStateBatchPreloader.new(account: account, conversation_ids: links.map(&:conversation_id)).perform
  end

  def shared_realtime_payload(communication_thread, links, source_conversation, message)
    payload = thread_identity_payload(communication_thread, links, source_conversation)
              .merge(thread_invariant_state_payload(communication_thread, links))
              .merge(thread_timing_payload(communication_thread, links))
    payload[:message_id] = message&.id
    payload[:message] = message_payload(message, communication_thread) if message.present?
    payload
  end

  def realtime_payload(communication_thread, links, shared_payload, read_states)
    channels = channel_payloads(communication_thread, links, read_states)
    shared_payload.merge(user_thread_state_payload(channels))
  end

  def thread_identity_payload(communication_thread, links, source_conversation)
    {
      id: communication_thread.display_id, communication_thread_id: communication_thread.display_id,
      is_communication_thread: true, meta: thread_meta(communication_thread, source_conversation),
      source_event: source_event, conversation_id: source_conversation.display_id,
      conversation_ids: links.map { |link| link.conversation.display_id },
      contact_id: communication_thread.contact_id, inbox_id: source_conversation.inbox_id,
      inbox_name: source_conversation.inbox&.name, contact_inbox_id: source_conversation.contact_inbox_id,
      channel: source_conversation.inbox&.channel_type, medium: thread_medium(source_conversation.inbox)
    }
  end

  def thread_invariant_state_payload(communication_thread, links)
    {
      status: communication_thread.status, priority: communication_thread.priority,
      assignee_id: communication_thread.assignee_id, team_id: communication_thread.team_id,
      labels: label_list(links), scheduling_appointment_statuses: scheduling_appointment_statuses(communication_thread)
    }
  end

  def user_thread_state_payload(channels)
    {
      channels: channels, can_reply: channels.any? { |channel| channel_replyable?(channel) },
      unread_count: channels.sum { |channel| channel[:unread_count].to_i }
    }
  end

  def thread_timing_payload(communication_thread, links)
    timestamps = directional_message_timestamps(communication_thread, links)
    {
      last_activity_at: communication_thread.last_activity_at.to_i, last_incoming_message_at: timestamps[:incoming]&.to_i,
      last_outgoing_message_at: timestamps[:outgoing]&.to_i, timestamp: communication_thread.last_activity_at.to_i,
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
    @thread_meta ||= {
      sender: communication_thread.contact.push_event_data(contact_inbox: source_conversation.contact_inbox),
      channel: 'CommunicationThread', assignee: communication_thread.assignee&.push_event_data,
      assignee_type: communication_thread.assignee.present? ? 'User' : nil, team: communication_thread.team&.push_event_data
    }
  end

  def channel_payloads(communication_thread, links, read_states)
    CommunicationThreads::ChannelCapabilitiesBuilder.new(
      links: links, contact: communication_thread.contact, deduplicate_linked: false,
      unread_counts: read_states.unread_counts, last_incoming_message_timestamps: @last_incoming_message_timestamps,
      last_seen_timestamps: read_states.last_seen_timestamps
    ).perform
  end

  def preload_conversation_directional_timestamps(account, links)
    preloader = Conversations::DirectionalMessageTimestampPreloader.new(account: account)
    @conversation_directional_timestamps = preloader.for_conversations(links.filter_map(&:conversation))
    @last_incoming_message_timestamps = @conversation_directional_timestamps.transform_values { |ts| ts[:incoming] }.compact
  end

  def directional_message_timestamps(communication_thread, links)
    return aggregate_directional_timestamps(links) if defined?(@conversation_directional_timestamps)

    preloader = Conversations::DirectionalMessageTimestampPreloader.new(account: communication_thread.account)
    preloader.for_communication_threads(communication_thread.id => links).fetch(communication_thread.id, {})
  end

  def aggregate_directional_timestamps(links)
    links.each_with_object({}) do |link, result|
      @conversation_directional_timestamps.fetch(link.conversation_id, {}).each do |side, created_at|
        result[side] = created_at if result[side].blank? || created_at > result[side]
      end
    end
  end

  def scheduling_appointment_statuses(communication_thread)
    @scheduling_appointment_statuses ||=
      Scheduling::AppointmentDialogStatusContextBuilder.new(account: communication_thread.account)
                                                       .for_communication_threads([communication_thread])
                                                       .fetch(communication_thread.id, [])
  end

  def channel_replyable?(channel)
    channel[:can_reply] || channel[:can_send_text] || channel[:requires_template] ||
      (channel[:channel] == 'Channel::Voice' && !channel[:disabled])
  end

  def label_list(links)
    links.flat_map do |link|
      conv = link.conversation
      conv&.association(:labels)&.loaded? ? conv.labels.map(&:name) : conv&.label_list
    end.compact.uniq
  end

  def broadcast(account, members, data)
    payload = data.merge(account_id: account.id)
    payload[:performer] = performer(account).push_event_data if performer(account).present?
    ActionCableBroadcastJob.perform_later(members.uniq, EVENT_NAME, payload)
  end

  def performer(account)
    return @performer if defined?(@performer)
    return @performer = nil if performer_id.blank?

    @performer = account.users.find_by(id: performer_id)
  end
end
