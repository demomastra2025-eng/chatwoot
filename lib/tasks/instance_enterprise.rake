# frozen_string_literal: true

namespace :chatwoot do
  namespace :instance do
    desc 'Force self-hosted enterprise mode and unlock all non-deprecated account features'
    task unlock_enterprise: :environment do
      if Rails.env.test?
        puts 'chatwoot:instance:unlock_enterprise is skipped in test'
        next
      end

      feature_definitions = YAML.safe_load(Rails.root.join('config/features.yml').read)
      enabled_features = feature_definitions.reject { |feature| feature['deprecated'] }.map { |feature| feature['name'] }
      default_features = feature_definitions.map { |feature| feature.merge('enabled' => !feature['deprecated']) }
      accounts_count = Account.count
      account_plan_name = ENV.fetch('CW_BOOTSTRAP_ACCOUNT_PLAN_NAME', 'Enterprise')

      bootstrap_installation_config('DEPLOYMENT_ENV', 'self-hosted')
      bootstrap_installation_config('INSTALLATION_PRICING_PLAN', 'enterprise')
      bootstrap_installation_config('INSTALLATION_PRICING_PLAN_QUANTITY', 1)
      bootstrap_feature_defaults(default_features)
      bootstrap_accounts(enabled_features, account_plan_name)
      GlobalConfig.clear_cache

      puts "Unlocked enterprise mode for #{accounts_count} account(s) with #{enabled_features.count} feature(s)"
    end

    private

    def bootstrap_installation_config(name, value)
      config = InstallationConfig.find_or_initialize_by(name: name)
      config.value = value
      config.save!
      puts "  #{name}=#{value}"
    end

    def bootstrap_feature_defaults(default_features)
      config = InstallationConfig.find_or_initialize_by(name: 'ACCOUNT_LEVEL_FEATURE_DEFAULTS')
      config.value = default_features
      config.locked = true if config.locked.nil?
      config.save!
      puts '  ACCOUNT_LEVEL_FEATURE_DEFAULTS updated'
    end

    def bootstrap_accounts(enabled_features, account_plan_name)
      Account.find_each do |account|
        account.custom_attributes = (account.custom_attributes || {}).merge('plan_name' => account_plan_name)
        account.enable_features(*enabled_features)
        account.save!
      end
      puts '  Existing accounts updated'
    end
  end

  namespace :dev do
    desc 'Alias for chatwoot:instance:unlock_enterprise'
    task unlock_enterprise: 'chatwoot:instance:unlock_enterprise'
  end
end
