class SuperAdmin::AppConfigsController < SuperAdmin::ApplicationController
  CAPTAIN_CONFIG_KEYS = %w[
    CAPTAIN_OPEN_AI_API_KEY CAPTAIN_DEFAULT_MODEL CAPTAIN_OPEN_AI_ENDPOINT
    CAPTAIN_ANTHROPIC_API_KEY CAPTAIN_ANTHROPIC_ENDPOINT
    CAPTAIN_GEMINI_API_KEY CAPTAIN_GEMINI_ENDPOINT
    CAPTAIN_OPENROUTER_API_KEY CAPTAIN_OPENROUTER_ENDPOINT
    CAPTAIN_MODERATION_MODEL
    CAPTAIN_AI_AGENT_SYSTEM_PROMPT CAPTAIN_AI_ASSISTANT_SYSTEM_PROMPT CAPTAIN_SYSTEM_PROMPTS
    ACCOUNT_CAPTAIN_TOKENS_LIMIT
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
    'whatsapp_embedded' => %w[WHATSAPP_APP_ID WHATSAPP_APP_SECRET WHATSAPP_CONFIGURATION_ID WHATSAPP_API_VERSION],
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
  end

  def create
    errors = []
    params['app_config'].each do |key, value|
      next unless @allowed_configs.include?(key)

      normalized_value = normalize_app_config_value(key, value, errors)
      next if normalized_value == :invalid

      i = InstallationConfig.where(name: key).first_or_create(value: normalized_value, locked: false)
      i.value = normalized_value
      errors.concat(i.errors.full_messages) unless i.save
    end

    if errors.any?
      redirect_to super_admin_app_config_path(config: @config), alert: errors.join(', ')
    else
      refresh_llm_config if @config == 'captain'
      redirect_to super_admin_settings_path, notice: "App Configs - #{@config.titleize} updated successfully"
    end
  end

  private

  def normalize_app_config_value(key, value, errors)
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

  def refresh_llm_config
    Llm::Config.reset!
    Llm::Config.initialize!
  rescue StandardError => e
    Rails.logger.warn("[SuperAdmin::AppConfigsController] Failed to refresh LLM config: #{e.class}: #{e.message}")
  end

  def set_config
    @config = params[:config] || 'general'
  end

  def allowed_configs
    @allowed_configs = APP_CONFIG_MAPPING.fetch(@config, DEFAULT_ALLOWED_CONFIGS)
  end
end

SuperAdmin::AppConfigsController.prepend_mod_with('SuperAdmin::AppConfigsController')
