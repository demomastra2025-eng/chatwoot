# frozen_string_literal: true

class Captain::Runtime::ChatFactory
  class << self
    def build(agent:, context_wrapper:, llm_context:, runtime_headers:, runtime_params:, account: nil)
      chat = Llm::ChatClient.build(**chat_build_kwargs(
        agent: agent,
        context_wrapper: context_wrapper,
        llm_context: llm_context,
        runtime_headers: runtime_headers,
        runtime_params: runtime_params,
        account: account
      ))

      configure(chat, agent, context_wrapper, account: account)
      Captain::Runtime::HistoryRestorer.restore(chat, context_wrapper.context[:conversation_history])
      context_wrapper.callback_manager.emit_chat_created(chat, agent.name, agent.model, context_wrapper)
      chat
    end

    private

    def chat_build_kwargs(agent:, context_wrapper:, llm_context:, runtime_headers:, runtime_params:, account: nil)
      {
        context: llm_context,
        model: agent.model,
        temperature: agent.temperature,
        params: merged_params(agent, runtime_params),
        headers: merged_headers(agent, runtime_headers),
        thinking: thinking_options(agent, context_wrapper, account: account)
      }.tap do |kwargs|
        kwargs[:account] = account if account.present?
      end
    end

    def configure(chat, agent, context_wrapper, account: nil)
      agent_tools = build_agent_tools(agent, context_wrapper)
      Llm::CapabilityPolicy.ensure_chat_features_supported!(
        model: agent.model,
        schema: agent.response_schema,
        tools: agent_tools,
        account: account
      )

      system_prompt = agent.get_system_prompt(context_wrapper)
      chat.with_instructions(system_prompt) if system_prompt.present?
      chat.with_tools(*agent_tools, replace: true)
      Llm::StructuredOutputPolicy.bind!(chat: chat, schema: agent.response_schema) if agent.response_schema.present?
      chat
    end

    def build_agent_tools(agent, context_wrapper)
      handoff_tools = agent.handoff_agents.map do |target_agent|
        Captain::Runtime::ToolWrapper.new(Captain::Runtime::HandoffTool.new(target_agent), context_wrapper)
      end

      regular_tools = agent.tools.map do |tool|
        Captain::Runtime::ToolWrapper.new(tool, context_wrapper)
      end

      handoff_tools + regular_tools
    end

    def merged_headers(agent, runtime_headers)
      Captain::Runtime::HashNormalizer.merge(agent.headers, runtime_headers)
    end

    def merged_params(agent, runtime_params)
      Captain::Runtime::HashNormalizer.merge(agent.params, runtime_params)
    end

    def thinking_options(agent, context_wrapper, account: nil)
      Llm::RuntimePolicy.thinking_options(
        feature: :assistant,
        model: agent.model,
        account: account,
        preferences: context_wrapper.context.dig(:state, :captain_runtime)
      )
    end
  end
end
