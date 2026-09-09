# frozen_string_literal: true

class Scheduling::ResourceTimezoneNormalizer
  DEFAULT_TIMEZONE = AccountWorkspaceWorkingHours::DEFAULT_TIMEZONE.freeze

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
      FROM scheduling_resources
      INNER JOIN accounts ON accounts.id = scheduling_resources.account_id
      WHERE scheduling_resources.timezone IS DISTINCT FROM (#{expected_timezone_sql})
    SQL
  end

  def update_sql
    <<~SQL.squish
      UPDATE scheduling_resources
      SET timezone = #{expected_timezone_sql}
      FROM accounts
      WHERE accounts.id = scheduling_resources.account_id
        AND scheduling_resources.timezone IS DISTINCT FROM (#{expected_timezone_sql})
    SQL
  end

  def expected_timezone_sql
    valid_timezones = TZInfo::Timezone.all_identifiers.map { |timezone| connection.quote(timezone) }.join(', ')

    @expected_timezone_sql ||= <<~SQL.squish
      CASE
        WHEN accounts.settings ->> 'workspace_timezone' IN (#{valid_timezones})
          THEN accounts.settings ->> 'workspace_timezone'
        ELSE #{connection.quote(DEFAULT_TIMEZONE)}
      END
    SQL
  end

  def connection
    ActiveRecord::Base.connection
  end
end
