# frozen_string_literal: true

class Llm::OpenRouterRequestCompiler
  RESPONSE_HEALING_PLUGIN_ID = Llm::OpenRouterRoutingProfile::RESPONSE_HEALING_PLUGIN_ID
  PRICE_SORT_VALUES = ['price', { by: 'price', partition: 'none' }, { 'by' => 'price', 'partition' => 'none' }].freeze
  PROVIDER_CONTROL_KEYS = %w[require_parameters allow_fallbacks data_collection zdr sort].freeze

  Compiled = Struct.new(:model, :models, :params, :headers, :native_endpoint, keyword_init: true)

  class << self
    def call(request: nil, model: nil, base_params: {}, stream: false, account: nil, feature: nil, schema: nil, tools: nil, reasoning: nil)
      compiler = new(
        request: request,
        model: model,
        base_params: base_params,
        stream: stream,
        account: account,
        feature: feature,
        schema: schema,
        tools: tools,
        reasoning: reasoning
      )
      compiler.call
    end
  end

  def initialize(request:, model:, base_params:, stream:, account:, feature:, schema:, tools:, reasoning:)
    @request = request
    @model = model.to_s.presence
    @base_params = base_params.respond_to?(:to_h) ? base_params.to_h.deep_dup : {}
    @stream = stream
    @account = account
    @feature = feature
    @schema = schema
    @tools = tools
    @reasoning = reasoning
  end

  def call
    profile = Llm::OpenRouterRoutingProfile.for(feature: feature_key, model: @model, account: @account)
    params = normalized_base_params
    provider_params = merged_provider_params(profile)
    plugins = merged_plugins(params, profile)

    params[:models] = profile.models if profile.models.present?
    params[:provider] = provider_params if provider_params.present?
    params[:plugins] = plugins if plugins.present?

    Compiled.new(
      model: @model,
      models: profile.models,
      params: params,
      headers: profile.headers,
      native_endpoint: profile.native_endpoint
    )
  end

  private

  def feature_key
    raw_feature = @feature.presence || request_value(:feature_key) || request_value(:feature) || 'captain_agent'
    Llm::OpenRouterRoutingProfile.normalize_feature(raw_feature)
  end

  def normalized_base_params
    @base_params.deep_dup.tap do |params|
      params.delete(:provider)
      params.delete('provider')
      params.delete(:plugins)
      params.delete('plugins')
    end
  end

  def merged_provider_params(profile)
    existing = normalize_provider_keys(extract_hash(@base_params[:provider] || @base_params['provider']))
    profile_preferences = normalize_provider_keys(profile.provider_preferences.deep_dup)

    existing.delete(:sort) if tool_flow? && price_sort?(existing[:sort])
    profile_preferences.delete(:sort) if tool_flow? && price_sort?(profile_preferences[:sort])

    require_parameters = requires_parameters?(profile_preferences)
    profile_preferences.delete(:require_parameters) unless require_parameters
    profile_preferences[:require_parameters] = true if require_parameters

    existing.deep_merge(profile_preferences).tap do |provider|
      provider.delete(:require_parameters) if provider[:require_parameters] == false
      provider.delete('require_parameters') if provider['require_parameters'] == false
    end
  end

  def merged_plugins(_params, profile)
    plugins = extract_plugins(@base_params[:plugins] || @base_params['plugins'])

    add_response_healing = schema_request? &&
                           !streaming? &&
                           profile.response_healing? &&
                           plugins.none? { |plugin| plugin_id(plugin) == RESPONSE_HEALING_PLUGIN_ID }
    plugins << { id: RESPONSE_HEALING_PLUGIN_ID } if add_response_healing

    plugins
  end

  def requires_parameters?(profile_preferences)
    profile_preferences[:require_parameters] == true || schema_request? || tool_flow? || reasoning_request?
  end

  def schema_request?
    return @schema unless @schema.nil?

    request_boolean(:requires_schema?) || request_boolean(:schema?) || request_value(:schema).present?
  end

  def tool_flow?
    return @tools unless @tools.nil?

    request_boolean(:requires_tools?) || Array(request_value(:tools)).present?
  end

  def reasoning_request?
    return @reasoning unless @reasoning.nil?

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

  def normalize_provider_keys(provider)
    provider.each_with_object({}) do |(key, value), result|
      normalized_key = PROVIDER_CONTROL_KEYS.include?(key.to_s) ? key.to_s.to_sym : key
      result[normalized_key] = value
    end
  end

  def extract_plugins(value)
    Array(value).filter_map do |plugin|
      plugin.respond_to?(:to_h) ? plugin.to_h.deep_dup : plugin
    end
  rescue StandardError
    []
  end

  def plugin_id(plugin)
    return unless plugin.respond_to?(:[])

    plugin[:id] || plugin['id']
  end

  def price_sort?(value)
    return true if value.to_s == 'price'
    return value[:by].to_s == 'price' || value['by'].to_s == 'price' if value.respond_to?(:[])

    PRICE_SORT_VALUES.include?(value)
  end
end
