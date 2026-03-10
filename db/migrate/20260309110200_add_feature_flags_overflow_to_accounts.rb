# frozen_string_literal: true

class AddFeatureFlagsOverflowToAccounts < ActiveRecord::Migration[7.1]
  def up
    add_column :accounts, :feature_flags_overflow, :jsonb, default: [], null: false

    Account.reset_column_information
    Account.find_each(batch_size: 100) do |account|
      account.enable_features!('scheduling', 'scheduling_finance')
    end
  end

  def down
    Account.reset_column_information
    Account.find_each(batch_size: 100) do |account|
      account.disable_features!('scheduling', 'scheduling_finance')
    end

    remove_column :accounts, :feature_flags_overflow
  end
end
