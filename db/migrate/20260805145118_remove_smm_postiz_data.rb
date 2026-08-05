class RemoveSmmPostizData < ActiveRecord::Migration[7.1]
  REMOVED_APP_ID = 'postiz'.freeze
  REMOVED_FEATURE = 'content'.freeze
  POSTIZ_TOMBSTONE_CONSTRAINT = 'integrations_hooks_app_id_not_postiz'.freeze

  def up
    remove_unregistered_hooks
    add_postiz_tombstone
    remove_account_feature_flags
    remove_account_feature_default
  end

  def down
    remove_postiz_tombstone
    say 'SMM/Postiz data cleanup is intentionally irreversible; removed credentials are not restored.'
  end

  private

  def remove_unregistered_hooks
    registered_app_ids = Integrations::App.all.map(&:id)
    raise 'Integration app registry is empty; refusing to delete hooks' if registered_app_ids.empty?

    unregistered_hooks = Integrations::Hook.where('app_id IS NULL OR app_id NOT IN (?)', registered_app_ids)
    deleted_hooks = unregistered_hooks.delete_all
    say "Removed #{deleted_hooks} unregistered integration hook(s)"
  end

  def add_postiz_tombstone
    return if check_constraint_exists?(:integrations_hooks, name: POSTIZ_TOMBSTONE_CONSTRAINT)

    add_check_constraint :integrations_hooks,
                         "app_id <> '#{REMOVED_APP_ID}'",
                         name: POSTIZ_TOMBSTONE_CONSTRAINT,
                         validate: false
    validate_check_constraint :integrations_hooks, name: POSTIZ_TOMBSTONE_CONSTRAINT
  end

  def remove_postiz_tombstone
    return unless check_constraint_exists?(:integrations_hooks, name: POSTIZ_TOMBSTONE_CONSTRAINT)

    remove_check_constraint :integrations_hooks, name: POSTIZ_TOMBSTONE_CONSTRAINT
  end

  def remove_account_feature_flags
    cleaned_accounts = 0
    Account.where.not(feature_flags_overflow: []).find_each do |account|
      existing_features = Array(account[:feature_flags_overflow]).map(&:to_s)
      cleaned_features = existing_features - [REMOVED_FEATURE]
      next if cleaned_features == existing_features

      # rubocop:disable Rails/SkipsModelValidations -- preserve unrelated flags on legacy rows that may no longer validate.
      account.update_columns(feature_flags_overflow: cleaned_features)
      # rubocop:enable Rails/SkipsModelValidations
      cleaned_accounts += 1
    end
    say "Removed the content feature flag from #{cleaned_accounts} account(s)"
  end

  def remove_account_feature_default
    config = InstallationConfig.find_by(name: 'ACCOUNT_LEVEL_FEATURE_DEFAULTS')
    return if config.blank?

    existing_defaults = Array(config.value)
    cleaned_defaults = existing_defaults.reject do |feature|
      feature.is_a?(Hash) && feature.with_indifferent_access[:name].to_s == REMOVED_FEATURE
    end
    return if cleaned_defaults == existing_defaults

    config.update!(value: cleaned_defaults)
    say 'Removed the content feature from account defaults'
  end
end
