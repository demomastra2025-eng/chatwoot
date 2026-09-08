class EnforceSingleSchedulingWorkRulePerWeekday < ActiveRecord::Migration[7.0]
  def up
    duplicate_groups = select_rows(<<~SQL.squish)
      SELECT resource_id, weekday
      FROM scheduling_work_rules
      GROUP BY resource_id, weekday
      HAVING COUNT(*) > 1
    SQL

    duplicate_groups.each { |resource_id, weekday| normalize_day!(resource_id, weekday) }

    # Keep the legacy slot-level index during the compatibility release. Old
    # application instances may still write more than one interval per day;
    # the stricter weekday constraint is added only after those writers are
    # fully retired in a later rollout.
  end

  def down
    # Data normalization is intentionally irreversible. Re-expanding a merged
    # interval cannot be done reliably without the original rows.
  end

  private

  def normalize_day!(resource_id, weekday)
    rules = select_all(<<~SQL.squish).to_a
      SELECT id, account_id, start_minute, end_minute, active
      FROM scheduling_work_rules
      WHERE resource_id = #{connection.quote(resource_id)}
        AND weekday = #{connection.quote(weekday)}
      ORDER BY start_minute, end_minute, id
      FOR UPDATE
    SQL
    active_rules = rules.select { |rule| truthy?(rule['active']) }
    keeper = active_rules.first || rules.first

    execute <<~SQL.squish
      DELETE FROM scheduling_work_rules
      WHERE resource_id = #{connection.quote(resource_id)}
        AND weekday = #{connection.quote(weekday)}
        AND id <> #{connection.quote(keeper['id'])}
    SQL
    return unless active_rules.present?

    intervals = merge_intervals(active_rules)
    execute <<~SQL.squish
      UPDATE scheduling_work_rules
      SET start_minute = #{intervals.first.first},
          end_minute = #{intervals.last.last},
          active = TRUE,
          updated_at = CURRENT_TIMESTAMP
      WHERE id = #{connection.quote(keeper['id'])}
    SQL
    intervals.each_cons(2) do |left, right|
      insert_gap_break!(keeper, resource_id, weekday, left.last, right.first)
    end
  end

  def merge_intervals(rules)
    rules.each_with_object([]) do |rule, intervals|
      interval = [rule['start_minute'].to_i, rule['end_minute'].to_i]
      if intervals.empty? || interval.first > intervals.last.last
        intervals << interval
      else
        intervals.last[1] = [interval.last, intervals.last.last].max
      end
    end
  end

  def insert_gap_break!(rule, resource_id, weekday, start_minute, end_minute)
    execute <<~SQL.squish
      INSERT INTO scheduling_break_rules
        (account_id, resource_id, weekday, start_minute, end_minute, title, active, created_at, updated_at)
      VALUES
        (#{connection.quote(rule['account_id'])}, #{connection.quote(resource_id)},
         #{connection.quote(weekday)}, #{start_minute}, #{end_minute}, 'Migrated interval gap', TRUE,
         CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      ON CONFLICT (resource_id, weekday, start_minute, end_minute)
      DO UPDATE SET
        account_id = EXCLUDED.account_id,
        active = TRUE,
        updated_at = CURRENT_TIMESTAMP
    SQL
  end

  def truthy?(value)
    [true, 1, '1', 't', 'true'].include?(value)
  end
end
