# frozen_string_literal: true

module Llm::Evals::OpenRouterContractSupport
  RESPONSE_HEALING_PLUGIN_ID = Llm::OpenRouterRoutingProfile::RESPONSE_HEALING_PLUGIN_ID

  ContractRequest = Struct.new(
    :feature_key,
    :tools_required,
    :schema_required,
    :reasoning_required,
    :runtime_preferences,
    :privacy_profile,
    :options,
    :messages,
    :reasoning,
    keyword_init: true
  ) do
    def requires_tools? = tools_required == true
    def requires_schema? = schema_required == true
    def reasoning? = reasoning_required == true
  end

  ContractAccount = Struct.new(:id, :captain_preferences, keyword_init: true)
  ContractConversation = Struct.new(:id, :display_id, keyword_init: true)

  ContractTool = Struct.new(:definition, keyword_init: true) do
    def name = definition[:id] || 'contract_tool'
    def tool_definition = definition
  end

  private

  def compile_contract_request(**attributes)
    request = ContractRequest.new(
      feature_key: attributes.fetch(:feature).to_s,
      tools_required: attributes.fetch(:tools, false),
      schema_required: attributes.fetch(:schema, false),
      reasoning_required: attributes.fetch(:reasoning_required, false),
      runtime_preferences: attributes[:runtime_preferences],
      privacy_profile: attributes[:privacy_profile],
      options: attributes[:options],
      messages: attributes[:messages],
      reasoning: attributes[:reasoning]
    )

    Llm::OpenRouterRequestCompiler.call(
      request: request,
      model: attributes.fetch(:model, 'moonshotai/kimi-k2.6'),
      base_params: attributes.fetch(:base_params, {}),
      stream: attributes.fetch(:stream, false),
      account: attributes[:account]
    )
  end

  def routing_profile(feature, strategy)
    Llm::OpenRouterRoutingProfile.for(
      feature: feature,
      model: 'openai/gpt-5.4',
      runtime_preferences: {
        openrouter_routing_strategy: strategy,
        openrouter_provider_order: %w[OpenAI Anthropic]
      }
    )
  end

  def plugin_ids(plugins)
    Array(plugins).filter_map { |plugin| plugin[:id] || plugin['id'] }
  end
end
