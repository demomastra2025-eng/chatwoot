class Api::V1::Accounts::Captain::PreferencesController < Api::V1::Accounts::BaseController
  OPENROUTER_PROVIDER = Llm::OpenRouterModelCatalog::PROVIDER
  INSTALLATION_MANAGED_MODEL_KEYS = Llm::Config::INSTALLATION_MANAGED_MODEL_CONFIGS.keys.freeze
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
    web_search_enabled
    web_scrape_enabled
    web_document_parse_enabled
  ].freeze
  RUNTIME_ROUTING_STRATEGY_KEYS = Llm::OpenRouterRoutingProfile::ROUTING_STRATEGY_KEYS.freeze
  RUNTIME_PROVIDER_ORDER_KEYS = Llm::OpenRouterRoutingProfile::PROVIDER_ORDER_KEYS.freeze
  RUNTIME_GUARDRAIL_ACTION_KEYS = %w[
    prompt_injection_guardrail
    sensitive_info_guardrail
    assistant_prompt_injection_guardrail
    assistant_sensitive_info_guardrail
    copilot_prompt_injection_guardrail
    copilot_sensitive_info_guardrail
  ].freeze

  before_action :current_account
  before_action :authorize_account_update, only: [:show, :update]

  def show
    render json: preferences_payload
  end

  def update
    locked_model_keys = requested_installation_managed_model_keys
    if locked_model_keys.any?
      return render json: {
        error: 'installation_managed_models',
        fields: locked_model_keys
      }, status: :unprocessable_content
    end

    params_to_update = captain_params
    Account.transaction do
      remove_stale_installation_managed_model_overrides
      @current_account.captain_models = params_to_update[:captain_models] if params_to_update[:captain_models]
      @current_account.captain_features = params_to_update[:captain_features] if params_to_update[:captain_features]
      @current_account.captain_runtime = params_to_update[:captain_runtime] if params_to_update[:captain_runtime]
      @current_account.captain_observability = params_to_update[:captain_observability] if params_to_update[:captain_observability]
      update_provider_credentials if provider_credentials_update?
      @current_account.save!
      update_account_budget_policy(params_to_update[:captain_budget]) if params_to_update.key?(:captain_budget)
    end

    render json: preferences_payload
  end

  private

  def preferences_payload
    Llm::Config.with_runtime_cache do
      Llm::OpenRouterModelCatalog.with_model_configs_snapshot do
        Llm::OpenRouterEndpointCatalog.with_endpoint_configs_snapshot do
          {
            providers: Llm::ProviderVisibilityPolicy.visible_providers,
            models: visible_models_payload,
            features: features_with_account_preferences,
            runtime: runtime_with_account_preferences,
            observability: observability_with_account_preferences,
            provider_credentials: provider_credentials_payload,
            usage: usage_payload,
            runtime_metadata: runtime_metadata_payload
          }
        end
      end
    end
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
    permitted[:captain_budget] = permitted_captain_budget if params[:captain_budget].present?
    permitted
  end

  def merged_captain_models
    existing_models = @current_account.captain_models.to_h.except(*INSTALLATION_MANAGED_MODEL_KEYS)
    existing_models.merge(permitted_captain_models)
  end

  def requested_installation_managed_model_keys
    raw_models = params[:captain_models]
    return [] unless raw_models.respond_to?(:keys)

    raw_models.keys.map(&:to_s) & INSTALLATION_MANAGED_MODEL_KEYS
  end

  def remove_stale_installation_managed_model_overrides
    current_models = @current_account.captain_models.to_h
    normalized_models = current_models.except(*INSTALLATION_MANAGED_MODEL_KEYS)
    @current_account.captain_models = normalized_models if normalized_models != current_models
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
      :editor, :assistant, :copilot, :label_suggestion, :moderation
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
      :privacy_profile,
      :assistant_thinking_effort,
      :copilot_thinking_effort,
      :assistant_moderation,
      :copilot_moderation,
      :moderation_failure_mode,
      :prompt_injection_guardrail,
      :sensitive_info_guardrail,
      :assistant_prompt_injection_guardrail,
      :assistant_sensitive_info_guardrail,
      :copilot_prompt_injection_guardrail,
      :copilot_sensitive_info_guardrail,
      :audio_transcription_prompt,
      :knowledge_chunk_size,
      :trace_input_capture,
      :trace_output_capture,
      :openrouter_routing_strategy,
      :routing_strategy,
      :agent_high_risk_tools,
      :web_search_enabled,
      :web_scrape_enabled,
      :web_document_parse_enabled,
      :web_search_max_results,
      :web_scrape_max_chars,
      :web_document_parse_max_chars,
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
      openrouter_provider_order: [],
      provider_order: [],
      agent_high_risk_tool_ids: [],
      agent_permissioned_tool_ids: [],
      web_allowed_domains: [],
      web_blocked_domains: []
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

  def permitted_captain_budget
    permitted = params.require(:captain_budget).permit(
      :active,
      :hard_stop,
      :daily_budget,
      :monthly_budget,
      :warning_threshold
    ).to_h.stringify_keys

    normalize_captain_budget(permitted)
  end

  def features_with_account_preferences
    preferences = Current.account.captain_preferences
    account_features = preferences[:features] || {}

    Llm::Models.feature_keys.index_with do |feature_key|
      config = Llm::Models.feature_config(feature_key, account: Current.account)
      selected_model = Llm::Config.model_for(feature: feature_key, account: Current.account)
      selected_diagnostics = if selected_model.present?
                               Llm::Models.capability_diagnostics_for(
                                 feature_key,
                                 selected_model,
                                 account: Current.account,
                                 runtime_preferences: preferences[:runtime]
                               ).to_h
                             end
      config.merge(
        enabled: account_features[feature_key] == true,
        selected: selected_model,
        selected_provider: selected_model.present? ? Llm::Config.provider_for_model(selected_model, account: Current.account) : nil,
        selected_supports_thinking: Llm::Models.supports_thinking?(selected_model, account: Current.account),
        selected_known_to_registry: Llm::Models.registry_known?(selected_model, account: Current.account),
        selected_diagnostics: selected_diagnostics
      )
    end
  end

  def runtime_with_account_preferences
    Current.account.captain_preferences[:runtime] || {}
  end

  def runtime_metadata_payload
    Llm::ModelRegistryService.runtime_metadata(account: Current.account).merge(
      web_access: web_access_metadata_payload,
      knowledge_indexing: Captain::KnowledgeSettings.metadata_for(Current.account).merge(
        chunk_size_options: Llm::Models.knowledge_chunk_size_options(account: Current.account)
      )
    )
  end

  def web_access_metadata_payload
    {
      provider: 'firecrawl',
      configured: Captain::Tools::FirecrawlService.configured?,
      deployment: Captain::Tools::FirecrawlService.self_hosted? ? 'self_hosted' : 'cloud',
      authentication_configured: Captain::Tools::FirecrawlService.authentication_configured?,
      search_default_results: Llm::RuntimePolicy::WEB_SEARCH_DEFAULT_LIMIT,
      search_max_results: Llm::RuntimePolicy::WEB_SEARCH_MAX_LIMIT,
      scrape_default_max_chars: Llm::RuntimePolicy::WEB_SCRAPE_DEFAULT_MAX_CHARS,
      scrape_max_chars: Llm::RuntimePolicy::WEB_SCRAPE_MAX_CHARS,
      document_parse_default_max_chars: Llm::RuntimePolicy::WEB_DOCUMENT_PARSE_DEFAULT_MAX_CHARS,
      document_parse_max_chars: Llm::RuntimePolicy::WEB_DOCUMENT_PARSE_MAX_CHARS,
      document_parse_max_file_bytes: Llm::RuntimePolicy.web_document_parse_max_file_bytes,
      document_parse_provider_max_file_bytes: Llm::RuntimePolicy::WEB_DOCUMENT_PARSE_PROVIDER_MAX_FILE_BYTES
    }
  end

  def usage_payload
    Llm::AccountUsageSummary.call(account: Current.account)
  end

  def observability_with_account_preferences
    Llm::Monitoring::AccountPreferences.for(Current.account)
  end

  def visible_models_payload
    Llm::Models.models(account: Current.account).select do |_model_name, model_config|
      Llm::ProviderVisibilityPolicy.visible_provider?(model_config.to_h['provider'])
    end
  end

  def provider_credentials_payload
    visible_provider_configs.each_with_object({}) do |(provider_name, provider_config), result|
      hook = provider_hook(provider_name)
      account_configured = provider_account_key_configured?(hook)
      result[provider_name] = {
        display_name: provider_config['display_name'].presence || provider_name,
        account_configured: account_configured,
        global_configured: Llm::Config.installation_provider_available?(provider_name),
        provider_configured: Llm::Config.provider_available?(provider_name, account: Current.account),
        source: provider_credential_source(provider_name, hook)
      }
      health = provider_health_payload(provider_name, result[provider_name][:source])
      result[provider_name][:health] = health if health.present?
    end
  end

  def visible_provider_configs
    Llm::ProviderVisibilityPolicy.visible_providers
  end

  def visible_provider_names
    visible_provider_configs.keys
  end

  def provider_credential_source(provider_name, hook)
    return 'account' if provider_account_key_configured?(hook)
    return 'global' if Llm::Config.installation_provider_available?(provider_name)

    'missing'
  end

  def provider_health_payload(provider_name, credential_source)
    return unless provider_name.to_s == OPENROUTER_PROVIDER

    case credential_source
    when 'account'
      { status: 'workspace_key_configured', source: 'account' }
    when 'global'
      global_openrouter_health_payload
    else
      { status: 'missing', source: 'missing' }
    end
  end

  def global_openrouter_health_payload
    health = Llm::OpenRouterKeyHealth.metadata.to_h.with_indifferent_access
    credits = health[:credits].to_h.with_indifferent_access
    {
      status: health[:status].presence || 'not_checked',
      source: 'global',
      checked_at: health[:checked_at],
      credits_status: credits[:status]
    }.compact
  end

  def provider_account_key_configured?(hook)
    hook&.access_token.present? || hook&.settings.to_h.with_indifferent_access[:api_key].present?
  end

  def provider_credentials_update?
    params[:provider_credentials].present? || params.key?(:openrouter_api_key) || params.key?(:remove_openrouter_api_key)
  end

  def update_provider_credentials
    provider_credentials_params.each do |provider_name, credentials|
      if credentials[:remove]
        provider_hook(provider_name)&.destroy!
        @provider_hooks&.delete(provider_name)
        next
      end

      token = credentials[:api_key].to_s.strip
      next if token.blank?

      hook = provider_hook(provider_name) || @current_account.hooks.build(app_id: provider_name, hook_type: 'account', status: 'enabled',
                                                                          settings: {})
      hook.access_token = token
      hook.settings = hook.settings.to_h.except('api_key')
      hook.status = 'enabled'
      hook.save!
      provider_hooks[provider_name] = hook
    end
  end

  def provider_credentials_params
    credentials = normalized_provider_credentials_params
    if params.key?(:openrouter_api_key) || params.key?(:remove_openrouter_api_key)
      credentials['openrouter'] = {
        api_key: params[:openrouter_api_key].to_s,
        remove: ActiveModel::Type::Boolean.new.cast(params[:remove_openrouter_api_key])
      }
    end
    credentials
  end

  def normalized_provider_credentials_params
    raw_credentials = params[:provider_credentials]
    return {} unless raw_credentials.respond_to?(:to_unsafe_h) || raw_credentials.is_a?(Hash)

    raw_hash = raw_credentials.respond_to?(:to_unsafe_h) ? raw_credentials.to_unsafe_h : raw_credentials
    raw_hash.slice(*visible_provider_names).each_with_object({}) do |(provider_name, values), result|
      next unless values.respond_to?(:to_unsafe_h) || values.is_a?(Hash)

      values_hash = values.respond_to?(:to_unsafe_h) ? values.to_unsafe_h : values
      values_hash = values_hash.with_indifferent_access
      result[provider_name] = {
        api_key: values_hash[:api_key].to_s,
        remove: ActiveModel::Type::Boolean.new.cast(values_hash[:remove])
      }
    end
  end

  def provider_hook(provider_name)
    provider_hooks[provider_name.to_s] ||= @current_account.hooks.find_by(app_id: provider_name.to_s, hook_type: 'account')
  end

  def provider_hooks
    @provider_hooks ||= {}
  end

  def normalize_captain_runtime(runtime)
    RUNTIME_BOOLEAN_KEYS.each do |key|
      runtime[key] = ActiveModel::Type::Boolean.new.cast(runtime[key]) if runtime.key?(key)
    end
    normalize_runtime_integer!(runtime, 'web_search_max_results', default: Llm::RuntimePolicy::WEB_SEARCH_DEFAULT_LIMIT,
                                                                  min: 1, max: Llm::RuntimePolicy::WEB_SEARCH_MAX_LIMIT)
    normalize_runtime_integer!(runtime, 'web_scrape_max_chars', default: Llm::RuntimePolicy::WEB_SCRAPE_DEFAULT_MAX_CHARS,
                                                                min: 1_000, max: Llm::RuntimePolicy::WEB_SCRAPE_MAX_CHARS)
    normalize_runtime_integer!(runtime, 'web_document_parse_max_chars', default: Llm::RuntimePolicy::WEB_DOCUMENT_PARSE_DEFAULT_MAX_CHARS,
                                                                        min: 1_000, max: Llm::RuntimePolicy::WEB_DOCUMENT_PARSE_MAX_CHARS)
    runtime['audio_transcription_prompt'] = runtime['audio_transcription_prompt'].to_s.strip if runtime.key?('audio_transcription_prompt')
    runtime['knowledge_chunk_size'] = normalize_knowledge_chunk_size(runtime['knowledge_chunk_size']) if runtime.key?('knowledge_chunk_size')
    normalize_runtime_domain_list!(runtime, 'web_allowed_domains')
    normalize_runtime_domain_list!(runtime, 'web_blocked_domains')
    RUNTIME_GUARDRAIL_ACTION_KEYS.each { |key| normalize_runtime_guardrail_action!(runtime, key) }
    RUNTIME_ROUTING_STRATEGY_KEYS.each { |key| normalize_runtime_routing_strategy!(runtime, key) }
    RUNTIME_PROVIDER_ORDER_KEYS.each { |key| normalize_runtime_provider_order!(runtime, key) }
    runtime['release_gate'] = normalize_release_gate(runtime['release_gate']) if runtime['release_gate'].present?
    runtime
  end

  def normalize_runtime_integer!(runtime, key, default:, min:, max:)
    return unless runtime.key?(key)

    runtime[key] = integer_value(runtime[key])
    runtime[key] = default unless runtime[key].is_a?(Integer)
    runtime[key] = runtime[key].clamp(min, max)
  end

  def normalize_runtime_domain_list!(runtime, key)
    return unless runtime.key?(key)

    runtime[key] = Array(runtime[key]).filter_map do |domain|
      domain.to_s.strip.downcase.delete_prefix('http://').delete_prefix('https://').split('/').first.presence
    end.uniq
  end

  def normalize_runtime_guardrail_action!(runtime, key)
    return unless runtime.key?(key)

    runtime[key] = normalize_guardrail_action(runtime[key])
  end

  def normalize_guardrail_action(value)
    Llm::RuntimePolicy.normalize_guardrail_action(value, default: 'block')
  end

  def normalize_runtime_routing_strategy!(runtime, key)
    return unless runtime.key?(key)

    strategy = runtime[key].to_s.strip.tr('-', '_')
    if Llm::OpenRouterRoutingProfile::ROUTING_STRATEGIES.include?(strategy)
      runtime[key] = strategy
    else
      runtime.delete(key)
    end
  end

  def normalize_runtime_provider_order!(runtime, key)
    return unless runtime.key?(key)

    order = Array(runtime[key]).map { |provider| provider.to_s.strip }.compact_blank
    order.present? ? runtime[key] = order : runtime.delete(key)
  end

  def normalize_knowledge_chunk_size(value)
    normalized = Captain::KnowledgeSettings.normalize_chunk_size(value)
    allowed_values = Llm::Models.knowledge_chunk_size_options(account: @current_account).reject { |option| option[:disabled] }.pluck(:value)
    return normalized if allowed_values.include?(normalized)
    return Captain::KnowledgeSettings::DEFAULT_CHUNK_SIZE if allowed_values.include?(Captain::KnowledgeSettings::DEFAULT_CHUNK_SIZE)

    allowed_values.first || normalized
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

  def normalize_captain_budget(config)
    %w[active hard_stop].each do |key|
      config[key] = ActiveModel::Type::Boolean.new.cast(config[key]) if config.key?(key)
    end
    %w[daily_budget monthly_budget warning_threshold].each do |key|
      config[key] = decimal_value(config[key]) if config.key?(key)
    end
    config
  end

  def update_account_budget_policy(config)
    policy = LlmBudgetPolicy.find_or_initialize_by(account_id: @current_account.id, scope_type: 'account', feature: nil)
    policy.assign_attributes(config)
    policy.account = @current_account
    policy.scope_type = 'account'
    policy.feature = nil
    policy.save!
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

  def decimal_value(value)
    return nil if value.blank?

    BigDecimal(value.to_s)
  rescue ArgumentError, TypeError
    value
  end
end
