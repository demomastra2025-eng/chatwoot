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
    result = SearchService.new(
      current_user: Current.user,
      current_account: Current.account,
      search_type: search_type,
      params: params
    ).perform
    preload_conversation_results(result)
  rescue ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_content
  end

  def preload_conversation_results(result)
    conversations = result[:conversations]&.to_a
    return result if conversations.blank?

    result[:conversations] = conversations
    if compact_conversation_results?
      @compact_conversation_results = true
      preload(conversations, [:contact, :inbox])
      return result
    end

    preload(conversations, [:contact, :inbox, :assignee])
    @conversation_first_messages = first_messages_by_conversation(conversations)
    attach_conversations_to_messages(@conversation_first_messages, conversations)
    preload_message_payload(@conversation_first_messages.values)
    result
  end

  def first_messages_by_conversation(conversations)
    Current.account.messages
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
