module Enterprise::SuperAdmin::AppConfigsController
  # The settings of the branding page (also read by SuperAdmin::InstallationConfigs to link a parameter to its page)
  CUSTOM_BRANDING_CONFIG_KEYS = %w[
    LOGO_THUMBNAIL
    LOGO
    LOGO_DARK
    BRAND_NAME
    INSTALLATION_NAME
    BRAND_URL
    WIDGET_BRAND_URL
    TERMS_URL
    PRIVACY_URL
    DISPLAY_MANIFEST
  ].freeze

  private

  # The branding page exists next to the pages of the community controller
  def known_configs
    super + %w[custom_branding]
  end

  def allowed_configs
    return super if ChatwootHub.pricing_plan == 'community'

    case @config
    when 'custom_branding'
      @allowed_configs = custom_branding_options
    when 'captain'
      @allowed_configs = captain_config_options
    else
      super
    end
  end

  def custom_branding_options
    CUSTOM_BRANDING_CONFIG_KEYS
  end

  # One list for the community and the enterprise page, so the page never offers fewer settings than the controller saves
  def captain_config_options
    SuperAdmin::AppConfigsController::CAPTAIN_CONFIG_KEYS
  end
end
