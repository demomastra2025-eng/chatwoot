# frozen_string_literal: true

class Llm::OpenRouterRequestCompiler
  RESPONSE_HEALING_PLUGIN_ID = Llm::OpenRouterRoutingProfile::RESPONSE_HEALING_PLUGIN_ID
  PROVIDER_CONTROL_KEYS = %w[
    order allow_fallbacks require_parameters data_collection zdr enforce_distillable_text only ignore
    quantizations sort preferred_min_throughput preferred_max_latency max_price
  ].freeze
  CALLER_PROVIDER_CONTROL_KEYS = %w[require_parameters allow_fallbacks data_collection zdr sort].freeze
  ENDPOINT_SCOPED_REQUEST_PARAMS = {
    temperature: 'temperature',
    parallel_tool_calls: 'parallel_tool_calls'
  }.freeze

  Compiled = Struct.new(:model, :models, :params, :headers, :native_endpoint, :metadata, keyword_init: true)

  class << self
    def call(
      request: nil, model: nil, base_params: {}, stream: false, account: nil, feature: nil, schema: nil,
      tools: nil, reasoning: nil, trusted_provider_params: false
    )
      compiler = new(
        request: request,
        model: model,
        base_params: base_params,
        stream: stream,
        account: account,
        feature: feature,
        schema: schema,
        tools: tools,
        reasoning: reasoning,
        trusted_provider_params: trusted_provider_params
      )
      compiler.call
    end
  end

  def initialize(request:, model:, base_params:, stream:, account:, feature:, schema:, tools:, reasoning:, trusted_provider_params:)
    @request = request
    @model = model.to_s.presence
    @base_params = base_params.respond_to?(:to_h) ? base_params.to_h.deep_dup : {}
    @stream = stream
    @account = account
    @feature = feature
    @schema = schema
    @tools = tools
    @reasoning = reasoning
    @trusted_provider_params = trusted_provider_params
    @omitted_params = []
  end

  def call
    profile = routing_profile
    feature_policy = openrouter_feature_policy(profile)
    params = normalized_base_params
    models = compiled_models(profile)
    provider_params = merged_provider_params(profile)
    transform_plan = context_transform_plan(feature_policy, models)
    publish_context_transform_event(transform_plan, models)
    plugins = merged_plugins(params, profile, feature_policy, transform_plan: transform_plan)
    server_tools = merged_server_tools(feature_policy)
    header_result = Llm::OpenRouterHeaders.build(
      cache_policy: feature_policy.cache_policy,
      provider_params: provider_params,
      native_endpoint: profile.native_endpoint,
      cache_options: request_options,
      privacy_profile: feature_policy.privacy_profile,
      trace_capture_allowed: feature_policy.workspace_policy&.trace_capture_allowed?
    )
    apply_request_params!(params, provider_params: provider_params, models: models)
    apply_parallel_tool_call_params!(params, provider_params: provider_params, models: models)
    apply_feature_policy_params!(params, feature_policy)
    params[:models] = models if models.present?
    params[:provider] = provider_params if provider_params.present?
    params[:plugins] = plugins if plugins.present?
    apply_server_tools!(params, server_tools)
    metadata = compiled_metadata(
      profile: profile,
      feature_policy: feature_policy,
      models: models,
      provider_params: provider_params,
      params: params,
      extensions: { plugins: plugins, server_tools: server_tools, transform_plan: transform_plan },
      header_metadata: header_result.metadata
    )

    Compiled.new(
      model: @model,
      models: models,
      params: params,
      headers: profile.headers.merge(header_result.headers),
      native_endpoint: profile.native_endpoint,
      metadata: metadata
    )
  end

  private

  def feature_key
    raw_feature = @feature.presence || request_value(:feature_key) || request_value(:feature) || 'captain_agent'
    Llm::OpenRouterRoutingProfile.normalize_feature(raw_feature)
  end

  def routing_profile
    Llm::OpenRouterRoutingProfile.for(
      feature: feature_key,
      model: @model,
      account: @account,
      runtime_preferences: request_value(:runtime_preferences),
      privacy_profile: request_value(:privacy_profile)
    )
  end

  def openrouter_feature_policy(_profile)
    return request_value(:openrouter_feature_policy) if request_value(:openrouter_feature_policy).present?

    Llm::OpenRouterFeaturePolicy.for(
      feature: feature_key,
      account: @account,
      runtime_preferences: request_value(:runtime_preferences),
      privacy_profile: request_value(:privacy_profile)
    )
  end

  def normalized_base_params
    @base_params.deep_dup.tap do |params|
      params.delete(:provider)
      params.delete('provider')
      params.delete(:plugins)
      params.delete('plugins')
      params.delete(:tools)
      params.delete('tools')
      params.delete(:server_tools)
      params.delete('server_tools')
      params.delete(:openrouter_server_tools)
      params.delete('openrouter_server_tools')
      params.delete(:service_tier)
      params.delete('service_tier')
      params.delete(:parallel_tool_calls)
      params.delete('parallel_tool_calls')
    end
  end

  def compiled_models(profile)
    request_models.presence || profile.models
  end

  def request_models
    Array(request_value(:models)).filter_map { |candidate| candidate.to_s.strip.presence }.uniq
  end

  def apply_request_params!(params, provider_params:, models:)
    set_param_if_present(params, :route, request_option(:route))
    set_param_if_present(params, :session_id, request_session_id)
    set_param_if_present(params, :tool_choice, request_value(:tool_choice))
    set_param_if_present(params, :reasoning, request_value(:reasoning)) if reasoning_request?
    set_param_if_present(params, :max_tokens, request_value(:max_tokens))
    unless suppress_unsupported_endpoint_param!(params, :temperature, request_value(:temperature), provider_params: provider_params, models: models)
      set_param_if_present(params, :temperature, request_value(:temperature))
    end
    set_param_if_present(params, :user, request_value(:user_id))
  end

  def apply_feature_policy_params!(params, feature_policy)
    set_param_if_present(params, :service_tier, feature_policy.compiled_service_tier)
  end

  def apply_parallel_tool_call_params!(params, provider_params:, models:)
    requested = desired_parallel_tool_calls
    return if requested.nil?

    if requested != true
      params.delete(:parallel_tool_calls)
      params.delete('parallel_tool_calls')
      return
    end

    supports_parallel_tools = route_explicitly_supports_endpoint_param?(
      models,
      :parallel_tool_calls,
      provider_params: provider_params
    )
    unless read_only_tool_flow? && supports_parallel_tools
      omit_request_param!(params, :parallel_tool_calls)
      return
    end

    params[:parallel_tool_calls] = true
  end

  def desired_parallel_tool_calls
    explicit = explicit_parallel_tool_calls_value
    return explicit unless explicit.nil?
    return true if read_only_tool_flow?
  end

  def explicit_parallel_tool_calls_value
    raw = request_value(:parallel_tool_calls)
    return ActiveModel::Type::Boolean.new.cast(raw) unless raw.nil?

    raw = @base_params[:parallel_tool_calls] if @base_params.key?(:parallel_tool_calls)
    raw = @base_params['parallel_tool_calls'] if raw.nil? && @base_params.key?('parallel_tool_calls')
    return if raw.nil?

    ActiveModel::Type::Boolean.new.cast(raw)
  end

  def read_only_tool_flow?
    tool_objects.present? && tool_objects.all? { |tool| Llm::ToolRiskPolicy.read_only?(tool) }
  end

  def tool_objects
    return Array(@tools) unless @tools.nil? || @tools == true || @tools == false

    Array(request_value(:tools))
  end

  def route_explicitly_supports_endpoint_param?(models, key, provider_params:)
    endpoint_param = ENDPOINT_SCOPED_REQUEST_PARAMS.fetch(key.to_sym)
    supported_parameters = primary_route_supported_parameters(models, provider_params: provider_params)
    return false if supported_parameters.blank?

    supported_parameters.include?(endpoint_param)
  rescue StandardError
    false
  end

  def omit_request_param!(params, key)
    params.delete(key)
    params.delete(key.to_s)
    @omitted_params << key.to_s
  end

  def set_param_if_present(params, key, value)
    return if value.blank?
    return if params.key?(key) || params.key?(key.to_s)

    params[key] = value
  end

  def merged_provider_params(profile)
    existing = safe_caller_provider_params(
      normalize_provider_keys(extract_hash(@base_params[:provider] || @base_params['provider']))
    )
    profile_preferences = normalize_provider_keys(profile.provider_preferences.deep_dup)

    existing.delete(:sort) if tool_flow? && price_sort?(existing[:sort])
    profile_preferences.delete(:sort) if tool_flow? && price_sort?(profile_preferences[:sort])

    require_parameters = requires_parameters?(profile_preferences)
    profile_preferences.delete(:require_parameters) unless require_parameters
    profile_preferences[:require_parameters] = true if require_parameters

    merged_provider_preferences(existing, profile_preferences).tap do |provider|
      if require_parameters
        provider[:require_parameters] = true
      else
        provider.delete(:require_parameters) if provider[:require_parameters] == false
        provider.delete('require_parameters') if provider['require_parameters'] == false
      end
    end
  end

  def merged_provider_preferences(existing, profile_preferences)
    return profile_preferences.deep_merge(existing) if @trusted_provider_params

    existing.deep_merge(profile_preferences)
  end

  def merged_plugins(_params, profile, feature_policy, transform_plan:)
    plugins = extract_plugins(@base_params[:plugins] || @base_params['plugins']).reject do |plugin|
      context_compression_plugin?(plugin)
    end
    default_allowed_ids = []

    if transform_plan&.plugin?
      plugins.unshift(transform_plan.plugin)
      default_allowed_ids << Llm::OpenRouterContextTransformPolicy::CONTEXT_COMPRESSION_PLUGIN_ID
    end

    if response_healing_allowed?(profile)
      plugins << { id: RESPONSE_HEALING_PLUGIN_ID }
      default_allowed_ids << RESPONSE_HEALING_PLUGIN_ID
    end

    feature_policy.filter_plugins(
      plugins: plugins,
      runtime_preferences: request_value(:runtime_preferences),
      default_allowed_ids: default_allowed_ids
    )
  end

  def merged_server_tools(feature_policy)
    feature_policy.filter_server_tools(requested_server_tools)
  end

  def context_transform_plan(feature_policy, models)
    Llm::OpenRouterContextTransformPolicy.call(
      messages: request_value(:messages),
      model: Array(models).first || @model,
      account: @account,
      policy: feature_policy.transform_policy
    )
  rescue StandardError => e
    Llm::OpenRouterContextTransformPolicy::Plan.new(
      status: 'failed',
      estimated_tokens: nil,
      context_limit: nil,
      soft_context_limit: nil,
      policy: feature_policy.transform_policy,
      reason: e.class.name.demodulize.underscore
    )
  end

  def publish_context_transform_event(transform_plan, models)
    return if transform_plan.blank?

    event_name = case transform_plan.status
                 when 'applied' then 'context_transform.applied'
                 when 'failed' then 'context_transform.failed'
                 else 'context_transform.skipped'
                 end
    payload = request_observability_hash.merge(
      feature: feature_key,
      model: Array(models).first || @model,
      status: transform_plan.status,
      provider: 'openrouter'
    ).merge(transform_plan.to_metadata)

    Llm::EventBus.publish(event_name, payload.compact)
  rescue StandardError => e
    Rails.logger.warn("[Llm::OpenRouterRequestCompiler] Failed to publish context transform event: #{e.class}: #{e.message}")
  end

  def compiled_metadata(profile:, feature_policy:, models:, provider_params:, params:, extensions:, header_metadata: {})
    {
      requested_model: @model,
      models: models,
      fallback_models: fallback_models(models),
      routing_profile: routing_profile_name(profile, provider_params),
      openrouter_provider_order: Array(provider_params[:order]).presence,
      openrouter_provider_sort: provider_sort(provider_params),
      openrouter_preferred_max_latency: provider_params[:preferred_max_latency],
      openrouter_preferred_min_throughput: provider_params[:preferred_min_throughput],
      openrouter_allow_fallbacks: provider_params[:allow_fallbacks],
      openrouter_require_parameters: provider_params[:require_parameters],
      openrouter_data_collection: provider_params[:data_collection],
      openrouter_zdr: provider_params[:zdr],
      openrouter_plugins: plugin_ids(extensions[:plugins]),
      openrouter_server_tools: server_tool_ids(extensions[:server_tools]),
      openrouter_service_tier: feature_policy.compiled_service_tier,
      openrouter_native_endpoint: profile.native_endpoint,
      openrouter_privacy_profile: feature_policy.privacy_profile,
      openrouter_guardrail_profile: feature_policy.guardrail_profile,
      openrouter_cache_policy: feature_policy.cache_policy,
      openrouter_plugin_policy: feature_policy.plugin_policy,
      openrouter_transform_policy: feature_policy.transform_policy,
      openrouter_budget_policy: feature_policy.budget_policy,
      openrouter_parallel_tool_calls: parallel_tool_calls_metadata(params),
      openrouter_omitted_params: @omitted_params.uniq.presence
    }.merge(extensions[:transform_plan]&.to_metadata || {}).merge(header_metadata || {}).compact
  end

  def fallback_models(models)
    return [] if models.blank?

    models.drop(@model.present? ? 1 : 0)
  end

  def parallel_tool_calls_metadata(params)
    return params[:parallel_tool_calls] if params.key?(:parallel_tool_calls)
    return params['parallel_tool_calls'] if params.key?('parallel_tool_calls')
  end

  def routing_profile_name(profile, provider_params)
    profile.routing_policy[:strategy].presence ||
      provider_sort(provider_params).presence ||
      (provider_params[:order].present? ? 'ordered' : 'balanced')
  end

  def provider_sort(provider_params)
    sort = provider_params[:sort]
    return sort.to_h.with_indifferent_access[:by].to_s.presence if sort.respond_to?(:to_h)
    return sort.to_s.presence if sort.present?
  end

  def plugin_ids(plugins)
    Array(plugins).filter_map { |plugin| hash_identifier(plugin) }.uniq.presence
  end

  def context_compression_plugin?(plugin)
    hash_identifier(plugin).to_s.tr('_', '-') == Llm::OpenRouterContextTransformPolicy::CONTEXT_COMPRESSION_PLUGIN_ID
  end

  def server_tool_ids(server_tools)
    Array(server_tools).filter_map { |tool| hash_identifier(tool) }.uniq.presence
  end

  def apply_server_tools!(params, server_tools)
    return if server_tools.blank?

    key = tool_flow? ? Llm::OpenRouterServerToolsPatch::SERVER_TOOLS_PARAM : :tools
    params[key] = server_tools
  end

  def hash_identifier(value)
    return value.to_s if value.is_a?(String) || value.is_a?(Symbol)
    return unless value.respond_to?(:to_h)

    hash_identifier_from_hash(value)
  end

  def hash_identifier_from_hash(value)
    hash = value.to_h.with_indifferent_access
    hash[:id].presence || hash[:name].presence || hash.dig(:function, :name).presence || hash[:type].presence
  rescue StandardError
    nil
  end

  def response_healing_allowed?(profile)
    schema_request? && !streaming? && profile.response_healing?
  end

  def requires_parameters?(profile_preferences)
    profile_preferences[:require_parameters] == true || schema_request? || tool_flow? || reasoning_request?
  end

  def suppress_unsupported_endpoint_param!(params, key, request_value, provider_params:, models:)
    return false unless strict_parameter_routing?(provider_params)
    return false unless endpoint_scoped_request_param?(key)
    return false if route_supports_endpoint_param?(models, key, provider_params: provider_params)
    return false unless params.key?(key) || params.key?(key.to_s) || request_value.present?

    params.delete(key)
    params.delete(key.to_s)
    params[Llm::OpenRouterServerToolsPatch::OMIT_TEMPERATURE_PARAM] = true if key == :temperature
    @omitted_params << key.to_s
    true
  end

  def strict_parameter_routing?(provider_params)
    provider_params.respond_to?(:to_h) && provider_params.to_h.with_indifferent_access[:require_parameters] == true
  end

  def endpoint_scoped_request_param?(key)
    ENDPOINT_SCOPED_REQUEST_PARAMS.key?(key.to_sym)
  end

  def route_supports_endpoint_param?(models, key, provider_params:)
    endpoint_param = ENDPOINT_SCOPED_REQUEST_PARAMS.fetch(key.to_sym)
    supported_parameters = primary_route_supported_parameters(models, provider_params: provider_params)
    return true if supported_parameters.blank?

    supported_parameters.include?(endpoint_param)
  rescue StandardError
    true
  end

  def primary_route_supported_parameters(models, provider_params:)
    primary_model = @model.presence || Array(models).first
    return [] if primary_model.blank?

    endpoint_parameters = constrained_primary_route_endpoints(primary_model, provider_params: provider_params).flat_map do |endpoint|
      Array(endpoint.to_h['supported_parameters']).map(&:to_s)
    end.uniq
    return endpoint_parameters if endpoint_parameters.present?

    model_config = Llm::Models.model_config(primary_model, account: @account)
    Array(model_config.to_h['supported_parameters'] || model_config.to_h[:supported_parameters]).map(&:to_s).uniq
  end

  def constrained_primary_route_endpoints(primary_model, provider_params:)
    endpoints = Llm::OpenRouterEndpointCatalog.endpoints_for(primary_model)
    return endpoints if endpoints.blank?

    provider = provider_params.respond_to?(:to_h) ? provider_params.to_h.with_indifferent_access : {}
    provider_names = endpoint_provider_filter(provider)
    ignored_provider_names = normalize_provider_names(provider[:ignore])
    endpoints = endpoints.reject { |endpoint| ignored_provider_names.include?(endpoint_provider_name(endpoint)) } if ignored_provider_names.present?
    return endpoints if provider_names.blank?

    filtered = endpoints.select { |endpoint| provider_names.include?(endpoint_provider_name(endpoint)) }
    filtered.presence || endpoints
  end

  def endpoint_provider_filter(provider)
    only = normalize_provider_names(provider[:only])
    return only if only.present?

    normalize_provider_names(provider[:order])
  end

  def normalize_provider_names(value)
    Array(value).filter_map { |provider| provider.to_s.strip.downcase.presence }.uniq
  end

  def endpoint_provider_name(endpoint)
    hash = endpoint.respond_to?(:to_h) ? endpoint.to_h.with_indifferent_access : {}
    (hash[:provider_name].presence || hash.dig(:provider, :name).presence || hash[:name].presence).to_s.strip.downcase
  rescue StandardError
    ''
  end

  def schema_request?
    return @schema.present? unless @schema.nil?

    request_boolean(:requires_schema?) || request_boolean(:schema?) || request_value(:schema).present?
  end

  def tool_flow?
    return Array(@tools).present? unless @tools.nil?

    request_boolean(:requires_tools?) || Array(request_value(:tools)).present?
  end

  def reasoning_request?
    return @reasoning.present? unless @reasoning.nil?

    request_boolean(:reasoning?) || request_value(:thinking).present? || request_value(:reasoning).present?
  end

  def streaming?
    return @stream unless @stream.nil?

    @base_params[:stream] == true || @base_params['stream'] == true
  end

  def request_value(method_name)
    return unless @request.respond_to?(method_name)

    @request.public_send(method_name)
  rescue StandardError
    nil
  end

  def request_boolean(method_name)
    request_value(method_name) == true
  end

  def extract_hash(value)
    return {} unless value.respond_to?(:to_h)

    value.to_h.deep_dup
  rescue StandardError
    {}
  end

  def safe_caller_provider_params(provider)
    allowed_keys = @trusted_provider_params ? PROVIDER_CONTROL_KEYS : CALLER_PROVIDER_CONTROL_KEYS
    provider.slice(*allowed_keys.map(&:to_sym))
  end

  def normalize_provider_keys(provider)
    provider.each_with_object({}) do |(key, value), result|
      normalized_key = PROVIDER_CONTROL_KEYS.include?(key.to_s) ? key.to_s.to_sym : key
      result[normalized_key] = value
    end
  end

  def request_options
    options = request_value(:options)
    return {} unless options.respond_to?(:to_h)

    options.to_h.deep_symbolize_keys
  rescue StandardError
    {}
  end

  def request_observability_hash
    observability = request_value(:observability)
    return {} unless observability.respond_to?(:to_h)

    observability.to_h.symbolize_keys
  rescue StandardError
    {}
  end

  def request_option(key)
    request_options[key]
  end

  def request_session_id
    request_value(:session_cache_key).presence || request_value(:session_id)
  end

  def requested_server_tools
    Array(request_value(:server_tools)) +
      Array(request_option(:server_tools)) +
      Array(request_option(:openrouter_server_tools))
  end

  def extract_plugins(value)
    Array(value).filter_map do |plugin|
      plugin.respond_to?(:to_h) ? plugin.to_h.deep_dup : plugin
    end
  rescue StandardError
    []
  end

  def price_sort?(value)
    return true if value.to_s == 'price'
    return false unless value.respond_to?(:to_h)

    sort = value.to_h
    sort[:by].to_s == 'price' || sort['by'].to_s == 'price'
  rescue StandardError
    false
  end
end
