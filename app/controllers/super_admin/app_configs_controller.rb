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

  # The changes the message after a save lists; the rest is «и ещё N»
  MAX_SUMMARY_LINES = 6

  helper SuperAdmin::AppConfigHelper
  before_action :set_config
  before_action :ensure_known_config
  before_action :allowed_configs
  helper_method :masked_secret_config?

  def show
    prepare_show
  end

  def create
    return create_ai_models if @config == 'captain'

    errors = persist_app_config

    if errors.any?
      redirect_to super_admin_app_config_path(config: @config), alert: errors.join('; ')
    else
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

  # What the page shows: the stored settings (a secret only as «set»), and on the AI models page its cards. `form` is the
  # form that was just sent and refused: its values and errors are shown instead of the stored ones.
  def prepare_show(form: nil)
    @app_config = stored_app_config
    @installation_configs = config_definitions
    secret_keys = @allowed_configs.select { |key| masked_secret_config?(key) }
    @configured_secrets = secret_keys.select { |key| @app_config[key].present? }
    prepare_ai_models_page(secret_keys, form) if @config == 'captain'
    # A secret never leaves the controller: the views get only whether it is set
    @app_config = @app_config.except(*secret_keys)
  end

  def stored_app_config
    # ref: https://github.com/rubocop/rubocop/issues/7767
    # rubocop:disable Style/HashTransformValues
    values = InstallationConfig.where(name: @allowed_configs)
                               .pluck(:name, :serialized_value)
                               .map { |name, serialized_value| [name, serialized_value['value']] }
                               .to_h
    # rubocop:enable Style/HashTransformValues
    return values unless @config == 'captain'

    prompts = Captain::Assistant::GLOBAL_SYSTEM_PROMPTS_INSTALLATION_CONFIG
    values.merge(prompts => values[prompts].presence || Captain::Assistant.installation_system_prompt_entries)
  end

  def prepare_ai_models_page(secret_keys, form)
    @openrouter_diagnostics = Llm::OpenRouterDiagnostics.call
    @ai_models_page = SuperAdmin::AiModelsPage.new(
      keys: @allowed_configs, values: @app_config, definitions: @installation_configs, masked_keys: secret_keys,
      submitted: form&.input.to_h, errors: form&.errors.to_h, options: SuperAdmin::AiModelOptions.new(recommended: recommended_models),
      history: SuperAdmin::AiModelsHistory.new(values: @app_config)
    )
    @unsaved_keys = form ? form.refused_keys : []
  end

  # The models the lists show first: the short list the platform has set (or the recommended one) and the built-in model
  def recommended_models
    Llm::Models.configured_model_allowlist.to_a + Llm::Models::DEFAULT_CURATED_MODELS + [Llm::Config::DEFAULT_MODEL]
  end

  # The AI models page is saved as a whole (SuperAdmin::AiModelsForm): either everything that was sent is saved, or
  # nothing is, and the page is shown again with what was sent and what is wrong with it.
  def create_ai_models
    stored = stored_app_config
    form = SuperAdmin::AiModelsForm.new(
      submitted: params.fetch('app_config', {}).to_unsafe_h, stored: stored, keys: @allowed_configs,
      masked_keys: @allowed_configs.select { |key| masked_secret_config?(key) }, confirmed_embedding: params[:confirm_embedding_change] == '1'
    )
    errors = form.save(actor: current_super_admin, request: request)
    return render_ai_models_errors(form, errors) if errors.any?

    after_ai_models_saved(form)
  end

  def after_ai_models_saved(form)
    if form.changes.any?
      expire_openrouter_key_health_cache
      refresh_llm_config
    end
    redirect_to super_admin_app_config_path(config: @config), notice: saved_notice(form)
  end

  def saved_notice(form)
    lines = form.summary
    return flash_text(:nothing_changed) if lines.empty?

    shown = lines.first(MAX_SUMMARY_LINES)
    rest = lines.size - shown.size
    flash_text(:saved_changes, changes: shown.join('; ') + (rest.positive? ? flash_text(:and_more, count: rest) : ''))
  end

  def render_ai_models_errors(form, errors)
    prepare_show(form: form)
    flash.now[:alert] = flash_text(:not_saved, count: errors.size)
    render :show, status: :unprocessable_content
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

    value
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
