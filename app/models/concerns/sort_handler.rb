module SortHandler
  extend ActiveSupport::Concern

  class_methods do # rubocop:disable Metrics/BlockLength
    def sort_on_last_activity_at(sort_direction = :desc)
      order(last_activity_at: sort_direction)
    end

    def sort_on_last_message_at(sort_direction = :desc)
      direction = sort_direction.to_s.downcase == 'asc' ? 'ASC' : 'DESC'

      select(Arel.sql("conversations.*, #{last_message_sort_timestamp_sql} AS last_message_activity_sort_at"))
        .order(generate_sql_query("last_message_activity_sort_at #{direction}, conversations.id #{direction}"))
    end

    def sort_on_created_at(sort_direction = :asc)
      order(created_at: sort_direction)
    end

    def sort_on_priority(sort_direction = :desc)
      order(generate_sql_query("priority #{sort_direction.to_s.upcase} NULLS LAST, last_activity_at DESC"))
    end

    def sort_on_priority_created_at(sort_direction = :desc)
      order(generate_sql_query("priority #{sort_direction.to_s.upcase} NULLS LAST, created_at ASC"))
    end

    def sort_on_waiting_since(sort_direction = :asc)
      order(generate_sql_query("waiting_since #{sort_direction.to_s.upcase} NULLS LAST, created_at ASC"))
    end

    def last_messaged_conversations
      Message.except(:order).select(
        'DISTINCT ON (conversation_id) conversation_id, id, created_at, message_type'
      ).order('conversation_id, created_at DESC')
    end

    def sort_on_last_user_message_at
      order('grouped_conversations.message_type', 'grouped_conversations.created_at ASC')
    end

    private

    def generate_sql_query(query)
      Arel::Nodes::SqlLiteral.new(sanitize_sql_for_order(query))
    end

    def last_message_sort_timestamp_sql
      activity_message_type = Message.message_types[:activity]

      <<~SQL.squish
        COALESCE(
          (
            SELECT MAX(messages.created_at)
            FROM messages
            WHERE messages.conversation_id = conversations.id
              AND messages.account_id = conversations.account_id
              AND messages.private = FALSE
              AND messages.message_type != #{activity_message_type}
          ),
          conversations.created_at
        )
      SQL
    end
  end
end
