class Api::V1::Accounts::SearchController < Api::V1::Accounts::BaseController
  def index
    @result = search('all')
  end

  def conversations
    @result = search('Conversation')
  end

  def contacts
    @result = search('Contact')
  end

  def messages
    @result = search('Message')
  end

  def articles
    @result = search('Article')
  end

  private

  def search(search_type)
    service = SearchService.new(
      current_user: Current.user,
      current_account: Current.account,
      search_type: search_type,
      params: params
    )
    result = service.perform
    # The text search of messages was cancelled by its time limit: what is shown may be incomplete.
    @messages_partial = service.messages_partial?
    preload_contact_results(preload_message_results(preload_conversation_results(result)))
  rescue ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_content
  end

  # The conversation, the sender and the attachments of the page of messages are read in a few queries, not per message
  # (about 3 queries and 8-10 ms of rendering for each of the 15 messages).
  def preload_message_results(result)
    messages = result[:messages]&.to_a
    return result if messages.blank?

    result[:messages] = messages
    preload(messages, [conversation: :communication_thread])
    preload_message_payload(messages)
    result
  end

  def preload_conversation_results(result)
    conversations = result[:conversations]&.to_a
    return result if conversations.blank?

    result[:conversations] = conversations
    if compact_conversation_results?
      @compact_conversation_results = true
      preload(conversations, [:contact, :inbox, :communication_thread])
      return result
    end

    preload(conversations, [:contact, :inbox, :assignee, :communication_thread])
    @conversation_first_messages = first_messages_by_conversation(conversations)
    attach_conversations_to_messages(@conversation_first_messages, conversations)
    preload_message_payload(@conversation_first_messages.values)
    result
  end

  def preload_contact_results(result)
    contacts = result[:contacts]&.to_a
    return result if contacts.blank?

    result[:contacts] = contacts
    @contact_latest_conversations = latest_conversations_by_contact(contacts.map(&:id))
    result
  end

  # One row per contact is picked in SQL, so a contact with a long history is not loaded whole to find its last
  # conversation. The access scope is a plain relation, or (custom role) a subquery aliased as "conversations", so the
  # columns are qualified with that name and both shapes accept DISTINCT ON.
  def latest_conversations_by_contact(contact_ids)
    Search::AccessScope.new(account: Current.account, user: Current.user)
                       .conversations.where(contact_id: contact_ids)
                       .select('DISTINCT ON (conversations.contact_id) conversations.*')
                       .reorder(Arel.sql('conversations.contact_id, conversations.last_activity_at DESC, conversations.id DESC'))
                       .preload(:communication_thread)
                       .index_by(&:contact_id)
  end

  def first_messages_by_conversation(conversations)
    Messages::TimelineVisibility.without_captain_tool_activity(Current.account.messages)
                                .where(conversation_id: conversations.map(&:id))
                                .select('DISTINCT ON (messages.conversation_id) messages.*')
                                .reorder(Arel.sql('messages.conversation_id, messages.created_at ASC, messages.id ASC'))
                                .index_by(&:conversation_id)
  end

  def attach_conversations_to_messages(messages_by_conversation, conversations)
    conversations_by_id = conversations.index_by(&:id)
    messages_by_conversation.each do |conversation_id, message|
      message.association(:conversation).target = conversations_by_id.fetch(conversation_id)
    end
  end

  def preload_message_payload(messages)
    return if messages.empty?

    preload(messages, [:sender, { attachments: { file_attachment: :blob } }])
    preload(messages.filter_map(&:sender).grep(Contact), Conversations::ListPreloader::CONTACT_ASSOCIATIONS)
    preload(messages.filter_map(&:sender).grep(User), Conversations::ListPreloader::USER_ASSOCIATIONS)
  end

  def preload(records, associations)
    ActiveRecord::Associations::Preloader.new(records: records, associations: associations).call
  end

  def compact_conversation_results?
    params[:compact].to_s == 'true'
  end
end
