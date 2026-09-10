class AddAccessControlModeToAccounts < ActiveRecord::Migration[7.1]
  MODES = %w[legacy shadow enforced].freeze
  CONSTRAINT_NAME = 'accounts_supported_access_control_mode'.freeze

  def up
    add_column :accounts, :access_control_mode, :string, default: 'legacy', null: false
    add_check_constraint :accounts,
                         "access_control_mode IN (#{MODES.map { |mode| connection.quote(mode) }.join(', ')})",
                         name: CONSTRAINT_NAME,
                         validate: false
    validate_check_constraint :accounts, name: CONSTRAINT_NAME
  end

  def down
    remove_check_constraint :accounts, name: CONSTRAINT_NAME
    remove_column :accounts, :access_control_mode
  end
end
