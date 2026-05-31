# frozen_string_literal: true

require 'json'

class Llm::Evals::OpenRouterClient
  DEFAULT_MAX_TOKENS = 800
  DEFAULT_TEMPERATURE = 0.0

  def initialize(**attributes)
    @account = attributes.fetch(:account)
    @mode = attributes.fetch(:mode, :judge).to_s
    @model = attributes[:model]
    @feature = attributes[:feature]
    @temperature = attributes.fetch(:temperature, DEFAULT_TEMPERATURE)
    @max_tokens = attributes.fetch(:max_tokens, DEFAULT_MAX_TOKENS)
    @runtime = attributes.fetch(:runtime, Llm::Runtime)
    @runtime_preferences = attributes.fetch(:runtime_preferences, {})
    @privacy_profile = attributes[:privacy_profile]
  end

  def call(request)
    normalized_request = request.to_h.deep_symbolize_keys
    response = @runtime.chat(feature_request(normalized_request))

    normalize_response(response, schema_payload(normalized_request).present?)
  end

  private

  def feature_request(request)
    schema = response_schema(request)

    Llm::FeatureRequest.new(
      feature: feature_for(schema),
      account: @account,
      model: @model,
      messages: messages_for(request),
      schema: schema,
      temperature: @temperature,
      max_tokens: @max_tokens,
      runtime_preferences: @runtime_preferences,
      privacy_profile: @privacy_profile,
      observability: observability_for(request),
      options: { stream: false }
    )
  end

  def feature_for(schema)
    return @feature if @feature.present?

    schema.present? ? :copilot : :editor
  end

  def messages_for(request)
    [
      { role: 'system', content: system_prompt_for(request) },
      { role: 'user', content: request_payload(request).to_json }
    ]
  end

  def system_prompt_for(request)
    return request[:system_prompt] if @mode == 'user_simulator' && request[:system_prompt].present?

    case @mode
    when 'user_simulator'
      'Simulate the next user message. Return JSON matching the provided schema.'
    else
      'Evaluate the scenario state strictly. Return JSON matching the provided schema.'
    end
  end

  def request_payload(request)
    request.except(:system_prompt, :response_schema, :response_contract)
  end

  def response_schema(request)
    schema = schema_payload(request)
    return if schema.blank?

    Llm::Evals::JsonSchema.new(name: "evals.#{@mode}.response", schema: schema)
  end

  def schema_payload(request)
    request[:response_schema].presence || request[:response_contract].presence
  end

  def observability_for(request)
    {
      feature: 'evals',
      eval_mode: @mode,
      scenario_thread_id: request[:thread_id]
    }.compact
  end

  def normalize_response(response, structured)
    content = response_content(response)
    return content unless structured
    return content.deep_symbolize_keys if content.respond_to?(:to_h)
    return {} unless json_like?(content)

    JSON.parse(content).deep_symbolize_keys
  rescue JSON::ParserError
    {}
  end

  def response_content(response)
    return response.content if response.respond_to?(:content)

    response
  end

  def json_like?(value)
    value.to_s.strip.start_with?('{', '[')
  end
end
