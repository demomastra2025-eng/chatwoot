class Conversations::DirectionalMessageTimestampPreloader
  INCOMING_MESSAGE_TYPE = Message.message_types[:incoming].freeze
  OUTGOING_MESSAGE_TYPES = [
    Message.message_types[:outgoing],
    Message.message_types[:template]
  ].freeze
  MESSAGE_TYPES = ([INCOMING_MESSAGE_TYPE] + OUTGOING_MESSAGE_TYPES).freeze

  def initialize(account:)
    @account = account
  end

  def for_conversations(conversations)
    for_conversation_ids(conversations.map(&:id))
  end

  def for_communication_threads(links_by_thread_id)
    links = links_by_thread_id.values.flatten
    timestamps_by_conversation_id = for_conversation_ids(links.filter_map(&:conversation_id))

    links_by_thread_id.transform_values do |thread_links|
      aggregate_thread_timestamps(thread_links, timestamps_by_conversation_id)
    end
  end

  private

  attr_reader :account

  def for_conversation_ids(conversation_ids)
    normalized_conversation_ids = conversation_ids.compact.uniq
    return {} if normalized_conversation_ids.empty?

    latest_directional_messages(normalized_conversation_ids).each_with_object({}) do |message, result|
      conversation_timestamps = result[message.conversation_id] ||= {}
      conversation_timestamps[message.read_attribute('direction_side').to_sym] = message.created_at
    end
  end

  def latest_directional_messages(conversation_ids)
    side_sql = directional_side_sql

    Message
      .where(
        account_id: account.id,
        conversation_id: conversation_ids,
        private: false,
        message_type: MESSAGE_TYPES
      )
      .select(
        "DISTINCT ON (messages.conversation_id, #{side_sql}) " \
        "messages.conversation_id, messages.created_at, #{side_sql} AS direction_side"
      )
      .reorder(Arel.sql("messages.conversation_id, #{side_sql}, messages.created_at DESC, messages.id DESC"))
  end

  def directional_side_sql
    "CASE WHEN messages.message_type = #{INCOMING_MESSAGE_TYPE} THEN 'incoming' ELSE 'outgoing' END"
  end

  def aggregate_thread_timestamps(thread_links, timestamps_by_conversation_id)
    thread_links.each_with_object({}) do |link, result|
      timestamps_by_conversation_id.fetch(link.conversation_id, {}).each do |side, created_at|
        result[side] = created_at if result[side].blank? || created_at > result[side]
      end
    end
  end
end
