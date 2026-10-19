# rubocop:disable Metrics/ClassLength
class SuperAdmin::AppConfigsController < SuperAdmin::ApplicationController
  MASKED_SECRET_CONFIG_KEYS = %w[
    CAPTAIN_OPENROUTER_API_KEY CAPTAIN_OPENROUTER_MANAGEMENT_API_KEY CAPTAIN_FIRECRAWL_API_KEY

    WHATSAPP_APP_SECRET WHATSAPP_WEBHOOK_VERIFY_TOKEN WHATSAPP_WEBHOOK_PUBLIC_VERIFY_TOKEN WHATSAPP_WEBHOOK_FORWARD_SECRET
  ].freeze
  CAPTAIN_CONFIG_KEYS = %w[
    CAPTAIN_OPENROUTER_API_KEY CAPTAIN_OPENROUTER_MANAGEMENT_API_KEY CAPTAIN_OPENROUTER_ENDPOINT
    CAPTAIN_FIRECRAWL_API_KEY
    CAPTAIN_DEFAULT_MODEL CAPTAIN_ASSISTANT_MODEL_ALLOWLIST CAPTAIN_AUDIO_TRANSCRIPTION_MODEL CAPTAIN_IMAGE_RECOGNITION_MODEL
    CAPTAIN_MODERATION_MODEL CAPTAIN_CUSTOM_GUARDRAIL_MODEL CAPTAIN_CUSTOMER_NOTICE_MODEL CAPTAIN_EMBEDDING_MODEL
    CAPTAIN_LABEL_SUGGESTION_MODEL CAPTAIN_OUTCOME_CLASSIFIER_MODEL CAPTAIN_LANGUAGE_DETECTION_MODEL
    CAPTAIN_AI_AGENT_SYSTEM_PROMPT CAPTAIN_AI_ASSISTANT_SYSTEM_PROMPT CAPTAIN_SYSTEM_PROMPTS
    ACCOUNT_CAPTAIN_TOKENS_LIMIT
  ].freeze
  WHATSAPP_WEBHOOK_ROUTING_CONFIG_KEYS = %w[
    WHATSAPP_WEBHOOK_ROUTING_RULES WHATSAPP_WEBHOOK_FORWARD_TARGETS
  ].freeze
  APP_CONFIG_MAPPING = {
    'facebook' => %w[FB_APP_ID FB_VERIFY_TOKEN FB_APP_SECRET IG_VERIFY_TOKEN FACEBOOK_API_VERSION ENABLE_MESSENGER_CHANNEL_HUMAN_AGENT],
    'microsoft' => %w[AZURE_APP_ID AZURE_APP_SECRET],
    'email' => %w[MAILER_INBOUND_EMAIL_DOMAIN ACCOUNT_EMAILS_LIMIT ACCOUNT_EMAILS_PLAN_LIMITS],
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
    'google' => %w[GOOGLE_OAUTH_CLIENT_ID GOOGLE_OAUTH_CLIENT_SECRET GOOGLE_OAUTH_REDIRECT_URI ENABLE_GOOGLE_OAUTH_LOGIN],
    'captain' => CAPTAIN_CONFIG_KEYS
  }.freeze
  DEFAULT_ALLOWED_CONFIGS = %w[
    ENABLE_ACCOUNT_SIGNUP FIREBASE_PROJECT_ID FIREBASE_CREDENTIALS WEBHOOK_TIMEOUT MAXIMUM_FILE_UPLOAD_SIZE
    WIDGET_TOKEN_EXPIRY ACCOUNT_CONVERSATIONS_LIMIT ACCOUNT_NON_WEB_INBOXES_LIMIT ACCOUNT_STORAGE_BYTES_LIMIT
    GRAFANA_OVERVIEW_DASHBOARD GRAFANA_LOGS_DASHBOARD
  ].freeze

  helper SuperAdmin::AppConfigHelper
  before_action :set_config
  before_action :ensure_known_config
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
    @installation_configs = config_definitions
    secret_keys = @allowed_configs.select { |key| masked_secret_config?(key) }
    @configured_secrets = secret_keys.select { |key| @app_config[key].present? }
    if @config == 'captain'
      @openrouter_diagnostics = Llm::OpenRouterDiagnostics.call
      @ai_models_page = SuperAdmin::AiModelsPage.new(
        keys: @allowed_configs, values: @app_config, definitions: @installation_configs, masked_keys: secret_keys
      )
    end
    # A secret never leaves the controller: the views get only whether it is set
    @app_config = @app_config.except(*secret_keys)
  end

  def create
    errors = persist_app_config

    if errors.any?
      redirect_to super_admin_app_config_path(config: @config), alert: errors.join('; ')
    else
      expire_openrouter_key_health_cache if @config == 'captain'
      refresh_llm_config if @config == 'captain'
      redirect_to super_admin_app_config_path(config: @config), notice: flash_text(:saved, page: SuperAdmin::AppConfigLabels.page_title(@config))
    end
  end

  def refresh_openrouter_models
    unless Llm::Config.installation_provider_available?(Llm::OpenRouterModelCatalog::PROVIDER)
      redirect_to super_admin_app_config_path(config: 'captain'), alert: flash_text(:openrouter_key_missing)
      return
    end
    catalog_block_reason = openrouter_catalog_refresh_block_reason
    if catalog_block_reason.present?
      redirect_to super_admin_app_config_path(config: 'captain'), alert: catalog_block_reason
      return
    end

    Internal::RefreshOpenRouterModelCatalogJob.perform_later
    redirect_to super_admin_app_config_path(config: 'captain'), notice: flash_text(:catalog_refresh_queued)
  end

  def refresh_openrouter_key_health
    unless Llm::OpenRouterKeyHealth.configured?
      redirect_to super_admin_app_config_path(config: 'captain'), alert: flash_text(:openrouter_key_missing)
      return
    end

    Internal::RefreshOpenRouterKeyHealthJob.perform_later
    redirect_to super_admin_app_config_path(config: 'captain'), notice: flash_text(:key_health_queued)
  end

  private

  def flash_text(key, **)
    I18n.t("super_admin.app_config.flashes.#{key}", **)
  end

  # The entries of config/installation_config.yml by name: display title, description, type, options
  def config_definitions
    @config_definitions ||= ConfigLoader.new.general_configs.each_with_object({}) do |config_hash, result|
      result[config_hash['name']] = config_hash.except('name')
    end
  end

  def config_title(key)
    SuperAdmin::AppConfigLabels.title(key, config_definitions[key])
  end

  def persist_app_config
    errors = []
    saver = SuperAdmin::AppConfigSaver.new(actor: current_super_admin, request: request)
    params.fetch('app_config', {}).each do |key, value|
      next unless @allowed_configs.include?(key)
      # A secret that is left empty keeps the stored value (the field never shows it, so empty means «do not change»)
      next if masked_secret_config?(key) && value.blank?

      normalized_value = normalize_app_config_value(key, value, errors)
      next if normalized_value == :invalid

      # Saved and, when the value changed, written to the audit log (never the value of a secret)
      errors.concat(saver.save(key, normalized_value, secret: masked_secret_config?(key)))
    end
    errors
  end

  # The Russian reason the catalog cannot be refreshed with the key in its present state, or nil
  def openrouter_catalog_refresh_block_reason
    status = Llm::OpenRouterKeyHealth.metadata.to_h.with_indifferent_access[:status].to_s
    return unless Llm::OpenRouterKeyHealth::CATALOG_REFRESH_BLOCKING_STATUSES.include?(status)

    flash_text("catalog_blocked.#{status}")
  end

  def normalize_app_config_value(key, value, errors)
    return normalize_json_object_config(key, value, errors) if WHATSAPP_WEBHOOK_ROUTING_CONFIG_KEYS.include?(key)
    return normalize_model_config(key, value, errors) if Llm::InstallationModelConfig.manages?(key)
    return normalize_system_prompts_config(value, errors) if key == Captain::Assistant::GLOBAL_SYSTEM_PROMPTS_INSTALLATION_CONFIG

    value
  end

  def normalize_system_prompts_config(value, errors)
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
    errors << flash_text(:prompts_invalid)
    :invalid
  end

  # A blank value keeps the built-in default; a filled one must be a catalog model fit for its feature, or a short
  # list of such models (see Llm::InstallationModelConfig).
  def normalize_model_config(key, value, errors)
    result = Llm::InstallationModelConfig.normalize(key, value)
    return result.value if result.valid?

    errors << flash_text(:field_error, title: config_title(key), key: key, error: result.error)
    :invalid
  end

  def normalize_json_object_config(key, value, errors)
    parsed_value = value.present? ? JSON.parse(value) : {}
    raise JSON::ParserError unless parsed_value.is_a?(Hash)

    JSON.generate(Whatsapp::WebhookIngressConfigValidator.validate!(key: key, value: parsed_value))
  rescue JSON::ParserError, Whatsapp::WebhookIngressRouter::ConfigurationError
    errors << flash_text(:json_object_invalid, title: config_title(key))
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

  # A secret: a setting whose value no page prints. The platform keys listed above, and every setting of the type
  # `secret` in config/installation_config.yml (or named like one).
  def masked_secret_config?(key)
    MASKED_SECRET_CONFIG_KEYS.include?(key.to_s) || SuperAdmin::InstallationConfigs.secret?(key.to_s, config_definitions[key.to_s])
  end

  def set_config
    @config = params[:config] || 'general'
  end

  # The pages of the settings. Any other `config` (a page that was removed, like «Служебные параметры» or Linear, or a
  # typo) is not found instead of showing the general settings under another name.
  def ensure_known_config
    raise ActionController::RoutingError, 'Not Found' unless known_configs.include?(@config)
  end

  def known_configs
    APP_CONFIG_MAPPING.keys + %w[general]
  end

  def allowed_configs
    @allowed_configs = APP_CONFIG_MAPPING.fetch(@config, DEFAULT_ALLOWED_CONFIGS)
  end
end

SuperAdmin::AppConfigsController.prepend_mod_with('SuperAdmin::AppConfigsController')

# rubocop:enable Metrics/ClassLength
