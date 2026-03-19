module Enterprise::Internal::CheckNewVersionsJob
  def perform
    super
    update_plan_info
    reconcile_premium_config_and_features
  end

  private

  def update_plan_info
    return if @instance_info.blank?

    sync_pricing_plan
    update_installation_config(key: 'CHATWOOT_SUPPORT_WEBSITE_TOKEN', value: @instance_info['chatwoot_support_website_token'])
    update_installation_config(key: 'CHATWOOT_SUPPORT_IDENTIFIER_HASH', value: @instance_info['chatwoot_support_identifier_hash'])
    update_installation_config(key: 'CHATWOOT_SUPPORT_SCRIPT_URL', value: @instance_info['chatwoot_support_script_url'])
  end

  def sync_pricing_plan
    if ChatwootApp.chatwoot_cloud?
      update_installation_config(key: 'INSTALLATION_PRICING_PLAN', value: @instance_info['plan'])
      update_installation_config(key: 'INSTALLATION_PRICING_PLAN_QUANTITY', value: @instance_info['plan_quantity'])
      return
    end

    update_installation_config(key: 'INSTALLATION_PRICING_PLAN', value: 'enterprise')
    update_installation_config(key: 'INSTALLATION_PRICING_PLAN_QUANTITY', value: self_hosted_pricing_plan_quantity)
  end

  def self_hosted_pricing_plan_quantity
    quantity = InstallationConfig.find_by(name: 'INSTALLATION_PRICING_PLAN_QUANTITY')&.value.to_i
    quantity.positive? ? quantity : 1
  end

  def update_installation_config(key:, value:)
    config = InstallationConfig.find_or_initialize_by(name: key)
    config.value = value
    config.locked = true
    config.save!
  end

  def reconcile_premium_config_and_features
    Internal::ReconcilePlanConfigService.new.perform
  end
end
