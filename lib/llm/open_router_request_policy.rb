# frozen_string_literal: true

class Llm::OpenRouterRequestPolicy
  OPENROUTER_PROVIDER = 'openrouter'
  RESPONSE_HEALING_PLUGIN_ID = 'response-healing'
  ROUTING_METADATA_IVAR = :@onelink_openrouter_routing_metadata

  class << self
    def tag!(chat, feature: nil, account: nil, model: nil, stream: nil)
      return chat unless chat

      metadata = routing_metadata(chat).merge(
        feature: feature.presence || routing_metadata(chat)[:feature],
        account: account.presence || routing_metadata(chat)[:account],
        model: model.presence || routing_metadata(chat)[:model],
        stream: stream.nil? ? routing_metadata(chat)[:stream] : stream
      ).compact
      chat.instance_variable_set(ROUTING_METADATA_IVAR, metadata)
      chat
    rescue StandardError
      chat
    end

    def require_parameters!(chat, account: nil, feature: nil, model: nil, tools: true, schema: false, reasoning: false, stream: nil)
      return chat unless openrouter_chat?(chat, account: account, model: model)
      return chat unless chat.respond_to?(:with_params)

      compiled = compile_chat_params(
        chat,
        account: account,
        feature: feature,
        model: model,
        tools: tools,
        schema: schema,
        reasoning: reasoning,
        stream: stream
      )
      chat.with_params(**compiled.params)
    end

    def require_structured_output!(chat, account: nil, feature: nil, model: nil, stream: nil)
      return chat unless openrouter_chat?(chat, account: account, model: model)
      return chat unless chat.respond_to?(:with_params)

      compiled = compile_chat_params(
        chat,
        account: account,
        feature: feature,
        model: model,
        tools: false,
        schema: true,
        reasoning: false,
        stream: stream
      )
      chat.with_params(**compiled.params)
    end

    def params_with_required_parameters(params, feature: nil, model: nil, account: nil, tools: true, schema: false, reasoning: false, stream: false)
      Llm::OpenRouterRequestCompiler.call(
        feature: feature,
        model: model,
        account: account,
        base_params: params,
        tools: tools,
        schema: schema,
        reasoning: reasoning,
        stream: stream
      ).params
    end

    def params_with_response_healing_plugin(params, feature: nil, model: nil, account: nil, stream: false)
      Llm::OpenRouterRequestCompiler.call(
        feature: feature,
        model: model,
        account: account,
        base_params: params,
        schema: true,
        stream: stream
      ).params
    end

    def openrouter_chat?(chat, account: nil, model: nil)
      chat_model = chat.respond_to?(:model) ? chat.model : nil
      provider = chat_model.respond_to?(:provider) ? chat_model.provider : nil
      return true if provider.to_s == OPENROUTER_PROVIDER

      metadata = routing_metadata(chat)
      model_id = chat_model.respond_to?(:id) ? chat_model.id : chat_model
      model_id = model.presence || metadata[:model] if model_id.blank?
      provider_for(model_id, account: account.presence || metadata[:account]) == OPENROUTER_PROVIDER
    rescue StandardError
      false
    end

    private

    def compile_chat_params(chat, account:, feature:, model:, tools:, schema:, reasoning:, stream:)
      metadata = routing_metadata(chat)
      Llm::OpenRouterRequestCompiler.call(
        feature: feature.presence || metadata[:feature],
        model: model.presence || metadata[:model].presence || model_id_for(chat),
        account: account.presence || metadata[:account],
        base_params: normalized_chat_params(chat),
        tools: tools,
        schema: schema,
        reasoning: reasoning,
        stream: stream.nil? ? metadata[:stream] : stream
      )
    end

    def routing_metadata(chat)
      return {} unless chat.respond_to?(:instance_variable_get)

      metadata = chat.instance_variable_get(ROUTING_METADATA_IVAR)
      metadata.respond_to?(:to_h) ? metadata.to_h.symbolize_keys : {}
    rescue StandardError
      {}
    end

    def normalized_chat_params(chat)
      raw_params = chat.respond_to?(:params) ? chat.params : {}
      return {} unless raw_params.respond_to?(:to_h)

      raw_params.to_h.deep_dup
    rescue StandardError
      {}
    end

    def extract_plugins(params)
      raw_plugins = params.delete(:plugins) || params.delete('plugins')
      Array(raw_plugins).filter_map do |plugin|
        plugin.respond_to?(:to_h) ? plugin.to_h.deep_dup : plugin
      end
    rescue StandardError
      []
    end

    def plugin_id(plugin)
      return unless plugin.respond_to?(:[])

      plugin[:id] || plugin['id']
    end

    def model_id_for(chat)
      model = chat.respond_to?(:model) ? chat.model : nil
      return model.id if model.respond_to?(:id)
      return model if model.present?
    end

    def provider_for(model_id, account: nil)
      return if model_id.blank?

      Llm::Models.provider_for(model_id.to_s, account: account)
    end
  end
end
