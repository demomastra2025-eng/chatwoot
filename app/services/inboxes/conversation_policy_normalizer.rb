# frozen_string_literal: true

class Inboxes::ConversationPolicyNormalizer
  def self.perform
    new.perform
  end

  def perform
    before_count = mismatch_count
    updated_count = connection.update(update_sql, self.class.name)
    remaining_count = mismatch_count

    {
      mismatches_before: before_count,
      rows_updated: updated_count,
      mismatches_after: remaining_count
    }
  end

  private

  def mismatch_count
    connection.select_value(<<~SQL.squish).to_i
      SELECT COUNT(*)
      FROM inboxes
      WHERE lock_to_single_conversation IS DISTINCT FROM (#{expected_value_sql})
    SQL
  end

  def update_sql
    <<~SQL.squish
      UPDATE inboxes
      SET lock_to_single_conversation = #{expected_value_sql}
      WHERE lock_to_single_conversation IS DISTINCT FROM (#{expected_value_sql})
    SQL
  end

  def expected_value_sql
    @expected_value_sql ||= <<~SQL.squish
      CASE
        WHEN channel_type = 'Channel::Email' THEN FALSE
        ELSE TRUE
      END
    SQL
  end

  def connection
    ActiveRecord::Base.connection
  end
end
