# Request-local data for the already authorized, paginated conversation list.
# Never attach cached counters to models: those models also serialize realtime events.
class Conversations::ListPreloader
  USER_ASSOCIATIONS = [:account_users, { avatar_attachment: :blob }].freeze
  PROFILE_ASSOCIATIONS = { avatar_attachment: :blob }.freeze
  CONTACT_ASSOCIATIONS = [
    { contact_channel_profiles: PROFILE_ASSOCIATIONS },
    { avatar_attachment: :blob },
    { owner: USER_ASSOCIATIONS }
  ].freeze

  def initialize(account:, conversations:)
    @account = account
    @conversations = Array(conversations)
    raise ArgumentError, 'Conversation account mismatch' if @conversations.any? { |conversation| conversation.account_id != account.id }

    @conversations_by_id = @conversations.index_by(&:id)
  end

  def perform
    return self if @conversations.empty?

    preload_conversations
    @last_messages = latest_messages
    @last_non_activity_messages = latest_messages(non_activity: true)
    preload_messages
    preload_message_state
    preload_labels
    self
  end

  def last_message(conversation)
    @last_messages[conversation.id]
  end

  def last_non_activity_message(conversation)
    @last_non_activity_messages[conversation.id]
  end

  def unread_count(conversation)
    @unread_counts.fetch(conversation.id, 0)
  end

  def can_reply?(conversation)
    return false if conversation.inbox.blank?

    Conversations::MessageWindowService.new(
      conversation, last_incoming_message_at: @last_incoming_timestamps[conversation.id]
    ).can_reply?
  end

  def labels(conversation)
    Labels::UnifiedAssignmentService.normalize(
      @contact_labels.fetch(conversation.contact_id, []) + @conversation_labels.fetch(conversation.id, [])
    )
  end

  def message_payload(message)
    return if message.nil?

    @message_payloads ||= {}
    @message_payloads[message.id] ||= message.push_event_data(
      conversation_unread_count: unread_count(@conversations_by_id.fetch(message.conversation_id))
    )
  end

  private

  def preload_conversations
    @conversations.each { |conversation| conversation.association(:account).target = @account }
    preload(@conversations, [
              { contact: CONTACT_ASSOCIATIONS }, { assignee: USER_ASSOCIATIONS },
              { contact_inbox: { channel_profile: PROFILE_ASSOCIATIONS } },
              { inbox: :channel }, :campaign, :team, :assignee_agent_bot,
              :conversation_participants, :communication_thread
            ])
  end

  def public_messages
    @account.messages.where(conversation_id: @conversations_by_id.keys, private: false)
  end

  def latest_messages(non_activity: false)
    return {} if @conversations.empty?

    scope = public_messages
    scope = scope.non_activity_messages if non_activity
    scope.select('DISTINCT ON (messages.conversation_id) messages.*')
         .reorder(Arel.sql('messages.conversation_id, messages.created_at DESC, messages.id DESC'))
         .index_by(&:conversation_id)
  end

  def preload_messages
    messages = @last_messages.values + @last_non_activity_messages.values
    messages.each { |message| reuse_conversation_associations(message) }
    preload(messages, [:sender, { inbox: :channel }, { attachments: { file_attachment: :blob } }])
    senders = messages.filter_map(&:sender)
    preload(senders.grep(Contact), CONTACT_ASSOCIATIONS)
    preload(senders.grep(User), USER_ASSOCIATIONS)
  end

  def reuse_conversation_associations(message)
    conversation = @conversations_by_id.fetch(message.conversation_id)
    message.association(:conversation).target = conversation
    message.association(:inbox).target = conversation.inbox if message.inbox_id == conversation.inbox_id
    message.association(:sender).target = conversation.contact if message.sender_type == 'Contact' && message.sender_id == conversation.contact_id
  end

  def preload_message_state
    incoming = @account.messages.reorder(nil).where(conversation_id: @conversations_by_id.keys).incoming
    @last_incoming_timestamps = incoming.group(:conversation_id).maximum(:created_at)
    @unread_counts = incoming.where(private: false).joins(:conversation)
                             .where('conversations.agent_last_seen_at IS NULL OR messages.created_at > conversations.agent_last_seen_at')
                             .group(:conversation_id).count
  end

  def preload_labels
    @contact_labels = label_names('Contact', @conversations.map(&:contact_id))
    @conversation_labels = label_names('Conversation', @conversations_by_id.keys)
  end

  def label_names(record_type, ids)
    return {} if ids.empty?

    ActsAsTaggableOn::Tagging
      .joins(:tag)
      .where(taggable_type: record_type, taggable_id: ids, context: 'labels', tagger_id: nil)
      .order('taggings.id')
      .pluck(:taggable_id, 'tags.name')
      .group_by(&:first).transform_values { |rows| rows.map(&:second) }
  end

  def preload(records, associations)
    return if records.empty?

    ActiveRecord::Associations::Preloader.new(records: records, associations: associations).call
  end
end
