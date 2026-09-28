class DisableReportRollupForAllAccounts < ActiveRecord::Migration[7.1]
  # report_rollup reclaimed mobile_v2's twentieth bit before overflow flags existed.
  REPORT_ROLLUP_FLAG = 1 << 19

  def up
    if column_exists?(:accounts, :feature_flags_overflow)
      # On installed schemas this feature is in the overflow array; bit 20 is mobile_v2.
      execute <<~SQL.squish
        UPDATE accounts
        SET feature_flags_overflow = feature_flags_overflow - 'report_rollup', updated_at = NOW()
        WHERE feature_flags_overflow ? 'report_rollup'
      SQL
    else
      execute <<~SQL.squish
        UPDATE accounts
        SET feature_flags = feature_flags & ~#{REPORT_ROLLUP_FLAG}, updated_at = NOW()
        WHERE (feature_flags & #{REPORT_ROLLUP_FLAG}) <> 0
      SQL
    end
  end
end
