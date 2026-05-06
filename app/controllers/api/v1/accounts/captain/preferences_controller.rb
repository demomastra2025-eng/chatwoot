class Api::V1::Accounts::Captain::PreferencesController < Api::V1::Accounts::BaseController
  RELEASE_GATE_INTEGER_KEYS = %w[
    min_request_count
    max_avg_duration_ms
    max_p95_duration_ms
  ].freeze
  RELEASE_GATE_FLOAT_KEYS = %w[
    max_error_rate
    max_schema_invalid_rate
    max_tool_failure_rate
    max_moderation_skipped_rate
    max_cost_per_request
    max_error_rate_regression
    max_avg_duration_regression
  ].freeze
  RUNTIME_BOOLEAN_KEYS = %w[
    assistant_moderation
    copilot_moderation
    trace_input_capture
    trace_output_capture
  ].freeze

  before_action :current_account
  before_action :authorize_account_update, only: [:update, :refresh_openrouter_models]

  def show
    render json: preferences_payload
  end

  def update
    params_to_update = captain_params
    @current_account.captain_models = params_to_update[:captain_models] if params_to_update[:captain_models]
    @current_account.captain_features = params_to_update[:captain_features] if params_to_update[:captain_features]
    @current_account.captain_runtime = params_to_update[:captain_runtime] if params_to_update[:captain_runtime]
    @current_account.captain_observability = params_to_update[:captain_observability] if params_to_update[:captain_observability]
    update_openrouter_credentials if openrouter_credentials_update?
    @current_account.save!

    render json: preferences_payload
  end

  def refresh_openrouter_models
    Llm::ModelRegistryService.refresh_openrouter!

    render json: preferences_payload
  rescue Llm::OpenRouterModelCatalog::MissingApiKeyError => e
    render json: preferences_payload.merge(error: e.message), status: :unprocessable_entity
  rescue StandardError => e
    sanitized_error = Llm::OpenRouterModelCatalog.sanitize_error_message(e)
    Rails.logger.warn("[Captain Preferences] OpenRouter model refresh failed: #{e.class}: #{sanitized_error}")
    render json: preferences_payload.merge(error: 'OpenRouter models refresh failed.'), status: :bad_gateway
  end

  private

  def preferences_payload
    {
      providers: Llm::Models.providers,
      models: Llm::Models.models(account: Current.account),
      features: features_with_account_preferences,
      runtime: runtime_with_account_preferences,
      observability: observability_with_account_preferences,
      provider_credentials: provider_credentials_payload,
      runtime_metadata: Llm::ModelRegistryService.runtime_metadata(account: Current.account)
    }
  end

  def authorize_account_update
    authorize @current_account, :update?
  end

  def captain_params
    permitted = {}
    permitted[:captain_models] = merged_captain_models if params[:captain_models].present?
    permitted[:captain_features] = merged_captain_features if params[:captain_features].present?
    permitted[:captain_runtime] = merged_captain_runtime if params[:captain_runtime].present?
    permitted[:captain_observability] = merged_captain_observability if params[:captain_observability].present?
    permitted
  end

  def merged_captain_models
    existing_models = @current_account.captain_models || {}
    existing_models.merge(permitted_captain_models)
  end

  def merged_captain_features
    existing_features = @current_account.captain_features || {}
    existing_features.merge(permitted_captain_features)
  end

  def merged_captain_runtime
    existing_runtime = @current_account.captain_runtime || {}
    existing_runtime.merge(permitted_captain_runtime)
  end

  def merged_captain_observability
    Llm::Monitoring::AccountPreferences.merge(
      account: @current_account,
      attributes: permitted_captain_observability
    )
  end

  def permitted_captain_models
    params.require(:captain_models).permit(
      :editor, :assistant, :copilot, :label_suggestion,
      :audio_transcription, :help_center_search, :moderation
    ).to_h.stringify_keys
  end

  def permitted_captain_features
    params.require(:captain_features).permit(
      :editor, :assistant, :copilot, :label_suggestion,
      :audio_transcription, :help_center_search
    ).to_h.stringify_keys
  end

  def permitted_captain_runtime
    permitted = params.require(:captain_runtime).permit(
      :assistant_thinking_effort,
      :copilot_thinking_effort,
      :assistant_moderation,
      :copilot_moderation,
      :moderation_failure_mode,
      :audio_transcription_prompt,
      :trace_input_capture,
      :trace_output_capture,
      :agent_high_risk_tools,
      release_gate: [
        :enabled,
        :min_request_count,
        :max_error_rate,
        :max_schema_invalid_rate,
        :max_tool_failure_rate,
        :max_moderation_skipped_rate,
        :max_avg_duration_ms,
        :max_p95_duration_ms,
        :max_cost_per_request,
        :max_error_rate_regression,
        :max_avg_duration_regression
      ],
      safety_blocklist: [],
      assistant_safety_blocklist: [],
      copilot_safety_blocklist: [],
      agent_high_risk_tool_ids: [],
      agent_permissioned_tool_ids: []
    ).to_h.stringify_keys

    normalize_captain_runtime(permitted)
  end

  def permitted_captain_observability
    params.require(:captain_observability).permit(
      :default_lookback_days,
      :retention_days,
      saved_views: [
        :id,
        :name,
        :tab,
        {
          filters: [
            :feature,
            :runtime_mode,
            :status,
            :flag,
            :model,
            :event_name,
            :tool_name,
            :schema_name,
            :trace_id,
            :session_id,
            :conversation_display_id,
            :copilot_thread_id,
            :assistant_id,
            :since,
            :until
          ]
        }
      ],
      alert_channels: [
        :enabled,
        :minimum_severity,
        :webhook_url,
        { email_recipients: [], notify_on: [] }
      ]
    ).to_h.stringify_keys
  end

  def features_with_account_preferences
    preferences = Current.account.captain_preferences
    account_features = preferences[:features] || {}

    Llm::Models.feature_keys.index_with do |feature_key|
      config = Llm::Models.feature_config(feature_key, account: Current.account)
      selected_model = Llm::Config.model_for(feature: feature_key, account: Current.account)
      config.merge(
        enabled: account_features[feature_key] == true,
        selected: selected_model,
        selected_provider: selected_model.present? ? Llm::Config.provider_for_model(selected_model, account: Current.account) : nil,
        selected_supports_thinking: Llm::Models.supports_thinking?(selected_model, account: Current.account),
        selected_known_to_registry: Llm::Models.registry_known?(selected_model, account: Current.account)
      )
    end
  end

  def runtime_with_account_preferences
    Current.account.captain_preferences[:runtime] || {}
  end

  def observability_with_account_preferences
    Llm::Monitoring::AccountPreferences.for(Current.account)
  end

  def provider_credentials_payload
    hook = openrouter_hook
    {
      openrouter: {
        account_configured: hook&.access_token.present?,
        global_configured: Llm::Config.installation_provider_available?('openrouter'),
        provider_configured: Llm::Config.provider_available?('openrouter', account: Current.account),
        source: provider_credential_source(hook)
      }
    }
  end

  def provider_credential_source(hook)
    return 'account' if hook&.access_token.present?
    return 'global' if Llm::Config.installation_provider_available?('openrouter')

    'missing'
  end

  def openrouter_credentials_update?
    params.key?(:openrouter_api_key) || params.key?(:remove_openrouter_api_key)
  end

  def update_openrouter_credentials
    if ActiveModel::Type::Boolean.new.cast(params[:remove_openrouter_api_key])
      openrouter_hook&.destroy!
      @openrouter_hook = nil
      return
    end

    token = params[:openrouter_api_key].to_s.strip
    return if token.blank?

    hook = openrouter_hook || @current_account.hooks.build(app_id: 'openrouter', hook_type: 'account', status: 'enabled', settings: {})
    hook.access_token = token
    hook.status = 'enabled'
    hook.save!
    @openrouter_hook = hook
  end

  def openrouter_hook
    @openrouter_hook ||= @current_account.hooks.find_by(app_id: 'openrouter', hook_type: 'account')
  end

  def normalize_captain_runtime(runtime)
    RUNTIME_BOOLEAN_KEYS.each do |key|
      runtime[key] = ActiveModel::Type::Boolean.new.cast(runtime[key]) if runtime.key?(key)
    end
    runtime['audio_transcription_prompt'] = runtime['audio_transcription_prompt'].to_s.strip if runtime.key?('audio_transcription_prompt')
    runtime['release_gate'] = normalize_release_gate(runtime['release_gate']) if runtime['release_gate'].present?
    runtime
  end

  def normalize_release_gate(config)
    config = config.to_h.stringify_keys
    config['enabled'] = ActiveModel::Type::Boolean.new.cast(config['enabled']) if config.key?('enabled')

    RELEASE_GATE_INTEGER_KEYS.each do |key|
      config[key] = integer_value(config[key]) if config.key?(key)
    end
    RELEASE_GATE_FLOAT_KEYS.each do |key|
      config[key] = float_value(config[key]) if config.key?(key)
    end

    config.compact
  end

  def integer_value(value)
    return nil if value.blank?

    Integer(value)
  rescue ArgumentError, TypeError
    value
  end

  def float_value(value)
    return nil if value.blank?

    Float(value)
  rescue ArgumentError, TypeError
    value
  end
end
