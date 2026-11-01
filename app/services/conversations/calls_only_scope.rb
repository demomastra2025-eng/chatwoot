# frozen_string_literal: true

class Conversations::CallsOnlyScope
  CALL_ATTRIBUTE_KEYS = %w[call_status call_provider call_direction].freeze
  VOICE_CHANNEL_TYPE = 'Channel::Voice'

  JSONB_CALL_ATTRIBUTES_SQL = <<~SQL.squish.freeze
    COALESCE(
      NULLIF(conversations.additional_attributes ->> 'call_status', ''),
      NULLIF(conversations.additional_attributes ->> 'call_provider', ''),
      NULLIF(conversations.additional_attributes ->> 'call_direction', '')
    ) IS NOT NULL
  SQL

  ACCOUNT_SCOPED_PREDICATE_SQL = <<~SQL.squish.freeze
    (
      conversations.id IN (
        SELECT tcs.conversation_id
        FROM telephony_call_sessions tcs
        WHERE tcs.account_id IN (:account_id)
          AND tcs.conversation_id IS NOT NULL
      )
      OR conversations.id IN (
        SELECT c.conversation_id
        FROM calls c
        WHERE c.account_id IN (:account_id)
          AND c.conversation_id IS NOT NULL
      )
      OR conversations.inbox_id IN (
        SELECT i.id
        FROM inboxes i
        WHERE i.account_id IN (:account_id)
          AND i.channel_type = 'Channel::Voice'
      )
      OR #{JSONB_CALL_ATTRIBUTES_SQL}
    )
  SQL

  PREDICATE_SQL = <<~SQL.squish.freeze
    (
      EXISTS (
        SELECT 1
        FROM telephony_call_sessions tcs
        WHERE tcs.account_id = conversations.account_id
          AND tcs.conversation_id = conversations.id
      )
      OR EXISTS (
        SELECT 1
        FROM calls c
        WHERE c.account_id = conversations.account_id
          AND c.conversation_id = conversations.id
      )
      OR EXISTS (
        SELECT 1
        FROM inboxes i
        WHERE i.id = conversations.inbox_id
          AND i.channel_type = 'Channel::Voice'
      )
      OR #{JSONB_CALL_ATTRIBUTES_SQL}
    )
  SQL

  class << self
    def apply(scope, account_id: nil)
      account_ids = resolve_account_ids(scope, account_id)
      return scope.where(Arel.sql(PREDICATE_SQL)) if account_ids.empty?

      predicate = ActiveRecord::Base.sanitize_sql_array(
        [ACCOUNT_SCOPED_PREDICATE_SQL, { account_id: account_ids }]
      )
      scope.where(Arel.sql(predicate))
    end

    def conversation_has_calls?(conversation)
      return false if conversation.blank?

      conversation_ids_with_calls(
        account_id: conversation.account_id,
        conversations: [conversation]
      ).include?(conversation.id)
    end

    def any_conversation_has_calls?(account_id:, conversations:)
      conversation_ids_with_calls(account_id: account_id, conversations: conversations).any?
    end

    def conversation_ids_with_calls(account_id:, conversations:)
      records = Array(conversations).compact
      return Set.new if records.empty?

      matched_ids = in_memory_call_conversation_ids(records)
      remaining = records.reject { |conversation| matched_ids.include?(conversation.id) }
      return matched_ids if remaining.empty?

      matched_ids.merge(voice_inbox_conversation_ids(account_id, remaining))
      remaining_ids = remaining.map(&:id) - matched_ids.to_a
      return matched_ids if remaining_ids.empty?

      matched_ids.merge(database_call_conversation_ids(account_id, remaining_ids))
    end

    private

    def resolve_account_ids(scope, account_id)
      raw = account_id.presence || scope_account_id(scope)
      return [] if raw.blank? || raw.is_a?(ActiveRecord::Relation)

      Array.wrap(raw).flatten.filter_map { |value| parse_account_id(value) }.uniq
    end

    def scope_account_id(scope)
      scope.where_values_hash['account_id'] if scope.respond_to?(:where_values_hash)
    end

    def parse_account_id(value)
      parsed = Integer(value, exception: false)
      parsed if parsed&.positive?
    end

    def in_memory_call_conversation_ids(records)
      records.each_with_object(Set.new) do |conversation, ids|
        ids.add(conversation.id) if additional_attributes_indicate_call?(conversation) || preloaded_voice_inbox?(conversation)
      end
    end

    def additional_attributes_indicate_call?(conversation)
      attrs = conversation.additional_attributes
      return false unless attrs.is_a?(Hash)

      CALL_ATTRIBUTE_KEYS.any? { |key| attrs[key].present? || attrs[key.to_sym].present? }
    end

    def preloaded_voice_inbox?(conversation)
      conversation.association(:inbox).loaded? && conversation.inbox&.channel_type == VOICE_CHANNEL_TYPE
    end

    def voice_inbox_conversation_ids(account_id, records)
      unloaded = records.reject { |conversation| conversation.association(:inbox).loaded? }
      return [] if unloaded.empty?

      inbox_scope = Inbox.where(
        id: unloaded.filter_map(&:inbox_id).uniq,
        channel_type: VOICE_CHANNEL_TYPE
      )
      inbox_scope = inbox_scope.where(account_id: account_id) if account_id.present?
      voice_inbox_ids = inbox_scope.pluck(:id).to_set
      unloaded.select { |conversation| voice_inbox_ids.include?(conversation.inbox_id) }.map(&:id)
    end

    def database_call_conversation_ids(account_id, conversation_ids)
      telephony_ids = Telephony::CallSession
                      .where(account_id: account_id, conversation_id: conversation_ids)
                      .distinct
                      .pluck(:conversation_id)
      still_remaining = conversation_ids - telephony_ids
      return telephony_ids if still_remaining.empty?

      telephony_ids + calls_table_conversation_ids(account_id, still_remaining)
    end

    def calls_table_conversation_ids(account_id, conversation_ids)
      sql = ActiveRecord::Base.sanitize_sql_array(
        ['SELECT DISTINCT conversation_id FROM calls WHERE account_id = ? AND conversation_id IN (?)',
         account_id, conversation_ids]
      )
      ActiveRecord::Base.connection.select_values(sql).map(&:to_i)
    end
  end
end
