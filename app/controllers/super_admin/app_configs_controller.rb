class SuperAdmin::AppConfigsController < SuperAdmin::ApplicationController
  MASKED_SECRET_CONFIG_KEYS = %w[
    CAPTAIN_OPENROUTER_API_KEY CAPTAIN_OPENROUTER_MANAGEMENT_API_KEY CAPTAIN_FIRECRAWL_API_KEY
    LINKEDIN_PERSONAL_GATEWAY_TOKEN LINKEDIN_PERSONAL_GATEWAY_MEDIA_SECRET
    WHATSAPP_APP_SECRET WHATSAPP_WEBHOOK_VERIFY_TOKEN WHATSAPP_WEBHOOK_PUBLIC_VERIFY_TOKEN WHATSAPP_WEBHOOK_FORWARD_SECRET
  ].freeze
  CAPTAIN_CONFIG_KEYS = %w[
    CAPTAIN_OPENROUTER_API_KEY CAPTAIN_OPENROUTER_MANAGEMENT_API_KEY CAPTAIN_OPENROUTER_ENDPOINT
    CAPTAIN_FIRECRAWL_API_KEY
    CAPTAIN_AI_AGENT_SYSTEM_PROMPT CAPTAIN_AI_ASSISTANT_SYSTEM_PROMPT CAPTAIN_SYSTEM_PROMPTS
    ACCOUNT_CAPTAIN_TOKENS_LIMIT
  ].freeze
  WHATSAPP_WEBHOOK_ROUTING_CONFIG_KEYS = %w[
    WHATSAPP_WEBHOOK_ROUTING_RULES WHATSAPP_WEBHOOK_FORWARD_TARGETS
  ].freeze
  APP_CONFIG_MAPPING = {
    'facebook' => %w[FB_APP_ID FB_VERIFY_TOKEN FB_APP_SECRET IG_VERIFY_TOKEN FACEBOOK_API_VERSION ENABLE_MESSENGER_CHANNEL_HUMAN_AGENT],
    'shopify' => %w[SHOPIFY_CLIENT_ID SHOPIFY_CLIENT_SECRET],
    'microsoft' => %w[AZURE_APP_ID AZURE_APP_SECRET],
    'email' => %w[MAILER_INBOUND_EMAIL_DOMAIN ACCOUNT_EMAILS_LIMIT ACCOUNT_EMAILS_PLAN_LIMITS],
    'linear' => %w[LINEAR_CLIENT_ID LINEAR_CLIENT_SECRET],
    'slack' => %w[SLACK_CLIENT_ID SLACK_CLIENT_SECRET],
    'instagram' => %w[INSTAGRAM_APP_ID INSTAGRAM_APP_SECRET INSTAGRAM_VERIFY_TOKEN INSTAGRAM_API_VERSION ENABLE_INSTAGRAM_CHANNEL_HUMAN_AGENT],
    'tiktok' => %w[TIKTOK_APP_ID TIKTOK_APP_SECRET TIKTOK_API_VERSION],
    'whatsapp_embedded' => %w[
      WHATSAPP_APP_ID WHATSAPP_APP_SECRET WHATSAPP_CONFIGURATION_ID WHATSAPP_WEBHOOK_VERIFY_TOKEN WHATSAPP_API_VERSION
      WHATSAPP_PROACTIVE_REAUTHORIZATION_ENABLED WHATSAPP_REQUIRE_NON_EXPIRING_SYSTEM_USER_TOKEN
      WHATSAPP_WEBHOOK_PUBLIC_INGRESS_URL WHATSAPP_WEBHOOK_PUBLIC_VERIFY_TOKEN
      WHATSAPP_WEBHOOK_ROUTING_RULES WHATSAPP_WEBHOOK_FORWARD_TARGETS
      WHATSAPP_WEBHOOK_FORWARD_SECRET WHATSAPP_WEBHOOK_RECEIVER_DESTINATION
    ],
    'linkedin_personal' => %w[
      LINKEDIN_PERSONAL_GATEWAY_URL LINKEDIN_PERSONAL_GATEWAY_TOKEN LINKEDIN_PERSONAL_GATEWAY_PUBLIC_BASE_URL
      LINKEDIN_PERSONAL_GATEWAY_MEDIA_SECRET LINKEDIN_PERSONAL_GRAPHQL_CONVERSATIONS_QUERY_ID
      LINKEDIN_PERSONAL_GRAPHQL_MESSAGES_QUERY_ID LINKEDIN_PERSONAL_SYNC_THREAD_LIMIT
      LINKEDIN_PERSONAL_SYNC_MESSAGE_LIMIT LINKEDIN_PERSONAL_POLL_INTERVAL_SECONDS LINKEDIN_PERSONAL_POLL_THREAD_LIMIT
      LINKEDIN_PERSONAL_POLL_MESSAGE_LIMIT LINKEDIN_PERSONAL_REQUEST_TIMEOUT_SECONDS
      LINKEDIN_PERSONAL_MIN_SEND_INTERVAL_SECONDS
    ],
    'notion' => %w[NOTION_CLIENT_ID NOTION_CLIENT_SECRET],
    'google' => %w[GOOGLE_OAUTH_CLIENT_ID GOOGLE_OAUTH_CLIENT_SECRET GOOGLE_OAUTH_REDIRECT_URI ENABLE_GOOGLE_OAUTH_LOGIN],
    'captain' => CAPTAIN_CONFIG_KEYS
  }.freeze
  DEFAULT_ALLOWED_CONFIGS = %w[
    ENABLE_ACCOUNT_SIGNUP FIREBASE_PROJECT_ID FIREBASE_CREDENTIALS WEBHOOK_TIMEOUT MAXIMUM_FILE_UPLOAD_SIZE
    WIDGET_TOKEN_EXPIRY ACCOUNT_CONVERSATIONS_LIMIT ACCOUNT_NON_WEB_INBOXES_LIMIT ACCOUNT_STORAGE_BYTES_LIMIT
  ].freeze

  before_action :set_config
  before_action :allowed_configs
  helper_method :masked_secret_config?

  def show
    # ref: https://github.com/rubocop/rubocop/issues/7767
    # rubocop:disable Style/HashTransformValues
    @app_config = InstallationConfig.where(name: @allowed_configs)
                                    .pluck(:name, :serialized_value)
                                    .map { |name, serialized_value| [name, serialized_value['value']] }
                                    .to_h
    # rubocop:enable Style/HashTransformValues
    @app_config[Captain::Assistant::GLOBAL_SYSTEM_PROMPTS_INSTALLATION_CONFIG] ||= Captain::Assistant.installation_system_prompt_entries
    @installation_configs = ConfigLoader.new.general_configs.each_with_object({}) do |config_hash, result|
      result[config_hash['name']] = config_hash.except('name')
    end
    return unless @config == 'captain'

    @openrouter_diagnostics = Llm::OpenRouterDiagnostics.call
  end

  def create
    errors = persist_app_config

    if errors.any?
      redirect_to super_admin_app_config_path(config: @config), alert: errors.join(', ')
    else
      expire_openrouter_key_health_cache if @config == 'captain'
      refresh_llm_config if @config == 'captain'
      redirect_to super_admin_settings_path, notice: "App Configs - #{@config.titleize} updated successfully"
    end
  end

  # rubocop:disable Rails/I18nLocaleTexts
  def refresh_openrouter_models
    unless Llm::Config.installation_provider_available?(Llm::OpenRouterModelCatalog::PROVIDER)
      redirect_to super_admin_app_config_path(config: 'captain'), alert: 'OpenRouter API key is not configured.'
      return
    end
    catalog_block_reason = openrouter_catalog_refresh_block_reason
    if catalog_block_reason.present?
      redirect_to super_admin_app_config_path(config: 'captain'), alert: catalog_block_reason
      return
    end

    Internal::RefreshOpenRouterModelCatalogJob.perform_later
    redirect_to(
      super_admin_app_config_path(config: 'captain'),
      notice: 'OpenRouter catalog refresh queued. Status and diff will update after the job finishes.'
    )
  end

  def refresh_openrouter_key_health
    unless Llm::OpenRouterKeyHealth.configured?
      redirect_to super_admin_app_config_path(config: 'captain'), alert: 'OpenRouter API key is not configured.'
      return
    end

    Internal::RefreshOpenRouterKeyHealthJob.perform_later
    redirect_to(
      super_admin_app_config_path(config: 'captain'),
      notice: 'OpenRouter key and credits health check queued.'
    )
  end
  # rubocop:enable Rails/I18nLocaleTexts

  private

  def persist_app_config
    errors = []
    params.fetch('app_config', {}).each do |key, value|
      next unless @allowed_configs.include?(key)
      next if preserve_masked_secret_config?(key, value)

      normalized_value = normalize_app_config_value(key, value, errors)
      next if normalized_value == :invalid

      i = InstallationConfig.where(name: key).first_or_create(value: normalized_value, locked: false)
      i.value = normalized_value
      errors.concat(i.errors.full_messages) unless i.save
    end
    errors
  end

  def openrouter_catalog_refresh_block_reason
    metadata = Llm::OpenRouterKeyHealth.metadata.to_h.with_indifferent_access
    return unless Llm::OpenRouterKeyHealth::CATALOG_REFRESH_BLOCKING_STATUSES.include?(metadata[:status].to_s)

    Llm::OpenRouterKeyHealth.catalog_refresh_block_reason(metadata)
  end

  def normalize_app_config_value(key, value, errors)
    return normalize_json_object_config(key, value, errors) if WHATSAPP_WEBHOOK_ROUTING_CONFIG_KEYS.include?(key)
    return value unless key == Captain::Assistant::GLOBAL_SYSTEM_PROMPTS_INSTALLATION_CONFIG

    parsed_value = value.present? ? JSON.parse(value) : []
    Captain::Assistant.normalize_installation_system_prompt_entries(parsed_value).map do |entry|
      {
        'id' => entry[:id],
        'type' => entry[:type],
        'group' => entry[:group],
        'content' => entry[:content],
        'slot' => entry[:slot]
      }
    end
  rescue JSON::ParserError
    errors << 'Captain system prompts must be valid JSON'
    :invalid
  end

  def normalize_json_object_config(key, value, errors)
    parsed_value = value.present? ? JSON.parse(value) : {}
    raise JSON::ParserError unless parsed_value.is_a?(Hash)

    JSON.generate(Whatsapp::WebhookIngressConfigValidator.validate!(key: key, value: parsed_value))
  rescue JSON::ParserError, Whatsapp::WebhookIngressRouter::ConfigurationError
    errors << "#{key.titleize} must be a supported JSON object"
    :invalid
  end

  def refresh_llm_config
    Llm::Config.reset!
    Llm::Config.initialize!
  rescue StandardError => e
    Rails.logger.warn("[SuperAdmin::AppConfigsController] Failed to refresh LLM config: #{e.class}: #{e.message}")
  end

  def expire_openrouter_key_health_cache
    return unless params.fetch('app_config', {}).keys.intersect?(MASKED_SECRET_CONFIG_KEYS)

    Rails.cache.delete(Llm::OpenRouterKeyHealth::CACHE_KEY)
  end

  def masked_secret_config?(key)
    MASKED_SECRET_CONFIG_KEYS.include?(key.to_s)
  end

  def preserve_masked_secret_config?(key, value)
    masked_secret_config?(key) && value.blank? && InstallationConfig.exists?(name: key)
  end

  def set_config
    @config = params[:config] || 'general'
  end

  def allowed_configs
    @allowed_configs = APP_CONFIG_MAPPING.fetch(@config, DEFAULT_ALLOWED_CONFIGS)
  end
end

SuperAdmin::AppConfigsController.prepend_mod_with('SuperAdmin::AppConfigsController')
