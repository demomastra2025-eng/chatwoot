class CommunicationThreads::CollaborationOccurrences::MessageAdapter # rubocop:disable Metrics/ClassLength
  RAILS_BLANK_STRING_CODEPOINTS = [
    9, 10, 11, 12, 13, 32, 133, 160, 5760, *8192..8202, 8232, 8233, 8239, 8287, 12_288
  ].freeze

  SOURCES = {
    'authored_customer_reply' => {
      source: 'messages.human_outgoing_public_retained_rows',
      private: false
    },
    'private_message' => {
      source: 'messages.outgoing_private_retained_rows',
      private: true
    }
  }.freeze

  attr_reader :account, :threads_scope, :from_time, :to_time, :fact_kind

  def initialize(account:, threads_scope:, from_time:, to_time:, fact_kind:)
    @account = account
    @threads_scope = threads_scope
    @from_time = from_time
    @to_time = to_time
    @fact_kind = fact_kind
  end

  def relation
    Message.unscoped.from("(#{occurrences_sql}) collaboration_occurrences").select('collaboration_occurrences.*')
  end

  def metadata
    {
      fact_kind: fact_kind,
      source: source_config.fetch(:source),
      availability: 'available_with_limitations',
      reliability: 'retained_but_deletable_partial_occurrence',
      retention: 'current_retained_message_rows_soft_delete_marker_preserved_physical_deletion_possible',
      as_of_supported: false,
      temporal_definition: 'message_created_at_in_workspace_half_open_window_current_retained_rows_only',
      actor_definition: 'persisted_sender_type_and_sender_id_without_polymorphic_constantization',
      limitations: 'edited_or_physically_deleted_messages_and_sender_identity_removed_by_nullification_are_not_reconstructable'
    }
  end

  private

  def occurrences_sql # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    <<~SQL.squish
      SELECT
        messages.id::bigint AS occurrence_id,
        links.communication_thread_id,
        messages.created_at AS occurred_at,
        #{quote(fact_kind)} AS fact_kind,
        #{quote(source_config.fetch(:source))} AS source,
        'retained_but_deletable_partial_occurrence' AS reliability,
        'current_retained_message_row' AS retention,
        #{actor_kind_sql} AS actor_kind,
        #{actor_type_sql} AS actor_type,
        messages.sender_id AS actor_id,
        NULL::varchar AS action,
        NULL::varchar AS action_actor_kind,
        NULL::varchar AS action_actor_type,
        NULL::bigint AS action_actor_id,
        #{deleted_sql} AS deleted,
        NULL::integer AS schema_version,
        NULL::timestamp AS reliable_since,
        NULL::text AS correlation_id
      FROM messages
      INNER JOIN communication_thread_conversations links
        ON links.account_id = messages.account_id
        AND links.conversation_id = messages.conversation_id
      INNER JOIN (#{visible_threads_sql}) visible_threads
        ON visible_threads.id = links.communication_thread_id
      WHERE messages.account_id = #{quote(account.id)}
        AND messages.message_type = #{Message.message_types.fetch('outgoing')}
        AND messages.private = #{quote(source_config.fetch(:private))}
        AND messages.content_type <> #{Message.content_types.fetch('voice_call')}
        #{authored_reply_predicate}
        AND messages.created_at >= #{quote(from_time.utc)}
        AND messages.created_at < #{quote(to_time.utc)}
    SQL
  end

  def actor_kind_sql
    <<~SQL.squish
      CASE
        WHEN messages.sender_type = 'User' THEN 'user'
        WHEN messages.sender_type = 'Captain::Assistant' THEN 'captain'
        WHEN messages.sender_type = 'Contact' THEN 'customer'
        WHEN messages.sender_type IS NULL
          AND messages.sender_id IS NULL
          AND NOT (#{content_attribute_present_sql('external_echo')}) THEN 'system'
        ELSE 'unknown'
      END
    SQL
  end

  def actor_type_sql
    <<~SQL.squish
      CASE
        WHEN messages.sender_type IS NULL
          AND messages.sender_id IS NULL
          AND NOT (#{content_attribute_present_sql('external_echo')}) THEN 'System'
        ELSE messages.sender_type
      END
    SQL
  end

  def authored_reply_predicate
    return '' unless fact_kind == 'authored_customer_reply'

    <<~SQL.squish
      AND (
        NOT (#{content_attribute_present_sql('automation_rule_id')})
        AND NOT (#{additional_attribute_present_sql('campaign_id')})
        AND (messages.sender_type = 'User' OR (#{content_attribute_present_sql('external_echo')}))
      )
    SQL
  end

  def deleted_sql
    content_attribute_truthy_sql('deleted')
  end

  def content_attribute_present_sql(key)
    json_attribute_present_sql(
      column: 'messages.content_attributes',
      type_function: 'json_typeof',
      key: key,
      string_container: :json_object
    )
  end

  def additional_attribute_present_sql(key)
    json_attribute_present_sql(
      column: 'messages.additional_attributes',
      type_function: 'jsonb_typeof',
      key: key,
      string_container: :key_substring
    )
  end

  def json_attribute_present_sql(column:, type_function:, key:, string_container:)
    <<~SQL.squish
      CASE
        WHEN #{type_function}(#{column}) = 'object' THEN
          #{json_object_attribute_present_sql(column, type_function, key)}
        #{string_container_presence_sql(column, type_function, key) if string_container == :json_object}
        #{string_key_presence_sql(column, type_function, key) if string_container == :key_substring}
        ELSE FALSE
      END
    SQL
  end

  def string_container_presence_sql(column, type_function, key)
    decoded = "COALESCE(#{column} #>> '{}', '')"
    decoded_jsonb = "(#{decoded})::jsonb"
    <<~SQL.squish
      WHEN #{type_function}(#{column}) = 'string' THEN
        CASE WHEN pg_input_is_valid(#{decoded}, 'jsonb') THEN
          CASE WHEN jsonb_typeof(#{decoded_jsonb}) = 'object'
            THEN #{json_object_attribute_present_sql(decoded_jsonb, 'jsonb_typeof', key)}
            ELSE FALSE
          END
        ELSE FALSE
        END
    SQL
  end

  def string_key_presence_sql(column, type_function, key)
    <<~SQL.squish
      WHEN #{type_function}(#{column}) = 'string' THEN
        POSITION(#{quote(key)} IN COALESCE(#{column} #>> '{}', '')) > 0
    SQL
  end

  def json_object_attribute_present_sql(column, type_function, key)
    value = "#{column} -> #{quote(key)}"
    <<~SQL.squish
      CASE #{type_function}(#{value})
        WHEN 'null' THEN FALSE
        WHEN 'boolean' THEN (#{column} ->> #{quote(key)})::boolean
        WHEN 'string' THEN BTRIM(#{column} ->> #{quote(key)}, #{rails_blank_string_chars_sql}) <> ''
        WHEN 'array' THEN jsonb_array_length((#{value})::jsonb) > 0
        WHEN 'object' THEN (#{value})::jsonb <> '{}'::jsonb
        WHEN 'number' THEN TRUE
        ELSE FALSE
      END
    SQL
  end

  def rails_blank_string_chars_sql
    @rails_blank_string_chars_sql ||= RAILS_BLANK_STRING_CODEPOINTS.map { |codepoint| "CHR(#{codepoint})" }.join(' || ')
  end

  def content_attribute_truthy_sql(key)
    quoted_key = Regexp.escape(key)
    <<~SQL.squish
      CASE
        WHEN json_typeof(messages.content_attributes) = 'object'
          THEN LOWER(COALESCE(messages.content_attributes ->> #{quote(key)}, 'false')) = 'true'
        WHEN json_typeof(messages.content_attributes) = 'string'
          THEN COALESCE(messages.content_attributes #>> '{}', '') ~*
            #{quote("\"#{quoted_key}\"\\s*:\\s*(true|\"true\")")}
        ELSE FALSE
      END
    SQL
  end

  def source_config
    SOURCES.fetch(fact_kind)
  end

  def visible_threads_sql
    threads_scope.where(account_id: account.id).reselect(:id).reorder(nil).to_sql
  end

  def quote(value)
    ActiveRecord::Base.connection.quote(value)
  end
end
