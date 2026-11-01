# frozen_string_literal: true

class Accounts::AiUsageRollout < ApplicationRecord
  self.table_name = 'account_ai_usage_rollouts'
  NAME = 'sent_messages_v1'

  def self.current
    create_or_find_by!(name: NAME)
  end

  def self.active?
    where(name: NAME).where.not(activated_at: nil).exists?
  end

  def self.indexes_ready?
    connection.select_value(<<~SQL.squish)
      SELECT COUNT(*) = 2 FROM pg_index
      WHERE indisvalid AND indexrelid IN (
        to_regclass('idx_messages_pending_ai_usage'), to_regclass('idx_reply_suggestion_identity_request'))
    SQL
  end

  def activate!(legacy_writers_drained: false)
    with_lock do
      return if activated_at
      raise 'Legacy billing writers must be drained before activation' unless legacy_writers_drained
      raise 'Historical source preparation is incomplete' unless prepared_at && cursor >= cutoff_message_id

      update!(activated_at: Time.current)
    end
  end
end
