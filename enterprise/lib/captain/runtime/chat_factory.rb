# frozen_string_literal: true

class Captain::Runtime::ChatFactory
  class << self
    def build(agent:, context_wrapper:, llm_context:, runtime_headers:, runtime_params:)
      chat = Llm::ChatClient.build(
        context: llm_context,
        model: agent.model,
        temperature: agent.temperature,
        params: merged_params(agent, runtime_params),
        headers: merged_headers(agent, runtime_headers),
        thinking: thinking_options(agent, context_wrapper)
      )

      configure(chat, agent, context_wrapper)
      Captain::Runtime::HistoryRestorer.restore(chat, context_wrapper.context[:conversation_history])
      context_wrapper.callback_manager.emit_chat_created(chat, agent.name, agent.model, context_wrapper)
      chat
    end

    private

    def configure(chat, agent, context_wrapper)
      system_prompt = agent.get_system_prompt(context_wrapper)
      chat.with_instructions(system_prompt) if system_prompt.present?
      chat.with_tools(*build_agent_tools(agent, context_wrapper), replace: true)
      chat.with_schema(agent.response_schema)
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

    def thinking_options(agent, context_wrapper)
      Llm::RuntimePolicy.thinking_options(
        feature: :assistant,
        model: agent.model,
        preferences: context_wrapper.context.dig(:state, :captain_runtime)
      )
    end
  end
end
