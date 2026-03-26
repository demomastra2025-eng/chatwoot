class DisableReportRollupForAllAccounts < ActiveRecord::Migration[7.1]
  def up
    Account.find_each(batch_size: 100) do |account|
      next unless account.feature_enabled?(:report_rollup)

      account.disable_features(:report_rollup)
      account.save!(validate: false)
    end
  end
end
