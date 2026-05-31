# frozen_string_literal: true

class Captain::Runtime::ChatFactory
  FINALIZATION_ONLY_INSTRUCTIONS = <<~PROMPT.squish.freeze
    Finalize the customer-facing Captain response using only the completed tool result messages already present in the conversation history.
    Do not request or imply another tool call. Return the required structured response for the customer.
  PROMPT

  class << self
    def build(agent:, context_wrapper:, llm_context:, runtime_headers:, runtime_params:, account: nil, finalization_only: false)
      chat = Llm::Runtime.build_chat(**chat_build_kwargs(
        agent: agent,
        context_wrapper: context_wrapper,
        llm_context: llm_context,
        runtime_headers: runtime_headers,
        runtime_params: runtime_params,
        account: account
      ))

      configure(chat, agent, context_wrapper, account: account, finalization_only: finalization_only)
      Captain::Runtime::HistoryRestorer.restore(chat, context_wrapper.context[:conversation_history])
      context_wrapper.callback_manager.emit_chat_created(chat, agent.name, agent.model, context_wrapper)
      chat
    end

    private

    def chat_build_kwargs(agent:, context_wrapper:, llm_context:, runtime_headers:, runtime_params:, account: nil)
      {
        feature: :captain_agent,
        account: account,
        model: agent.model,
        options: {
          context: llm_context,
          temperature: agent.temperature,
          params: merged_params(agent, runtime_params),
          headers: merged_headers(agent, runtime_headers),
          thinking: thinking_options(agent, context_wrapper, account: account)
        }
      }
    end

    def configure(chat, agent, context_wrapper, account: nil, finalization_only: false)
      record_bound_agent_tools(agent, context_wrapper, finalization_only: finalization_only)
      agent_tools = finalization_only ? [] : build_agent_tools(agent, context_wrapper)
      Llm::CapabilityPolicy.ensure_chat_features_supported!(
        model: agent.model,
        schema: agent.response_schema,
        tools: agent_tools,
        account: account
      )

      system_prompt = system_prompt_for(agent, context_wrapper, finalization_only: finalization_only)
      chat.with_instructions(system_prompt) if system_prompt.present?
      enforce_openrouter_tool_parameters!(chat, agent_tools, account: account, schema: agent.response_schema)
      chat.with_tools(*agent_tools, replace: true) if agent_tools.present?
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

    def system_prompt_for(agent, context_wrapper, finalization_only: false)
      prompts = []
      prompt = agent.get_system_prompt(context_wrapper)
      prompts << prompt if prompt.present?
      prompts << FINALIZATION_ONLY_INSTRUCTIONS if finalization_only
      prompts.join("\n\n")
    end

    def enforce_openrouter_tool_parameters!(chat, agent_tools, account: nil, schema: nil)
      return if agent_tools.blank?

      Llm::OpenRouterRequestPolicy.require_parameters!(
        chat,
        account: account,
        feature: :captain_agent,
        model: model_id_for(chat),
        tools: true,
        schema: schema.present?
      )
    end

    def model_id_for(chat)
      chat_model = chat.respond_to?(:model) ? chat.model : nil
      return chat_model.id if chat_model.respond_to?(:id)
      return chat_model if chat_model.present?
    end

    def record_bound_agent_tools(agent, context_wrapper, finalization_only: false)
      bound_tool_names = finalization_only ? [] : (handoff_tool_names(agent) + regular_tool_names(agent)).uniq

      context_wrapper.context[:current_agent] = agent.name
      context_wrapper.context[:captain_v2_bound_tool_ids_by_agent] ||= {}
      context_wrapper.context[:captain_v2_bound_tool_ids_by_agent][agent.name.to_s] =
        bound_tool_names
      context_wrapper.context[:captain_v2_bound_tool_ids] = bound_tool_names
      context_wrapper.context[:captain_v2_bound_tool_gate] = true
    end

    def handoff_tool_names(agent)
      agent.handoff_agents.map do |target_agent|
        Captain::HandoffNaming.tool_name_for(target_agent.name)
      end
    end

    def regular_tool_names(agent)
      agent.tools.map { |tool| tool.name.to_s }
    end

    def merged_headers(agent, runtime_headers)
      Captain::Runtime::HashNormalizer.merge(agent.headers, runtime_headers)
    end

    def merged_params(agent, runtime_params)
      Captain::Runtime::HashNormalizer.merge(agent.params, runtime_params).tap do |params|
        params[:parallel_tool_calls] = false if mutating_tools?(agent)
      end
    end

    def mutating_tools?(agent)
      return true if agent.handoff_agents.present?

      agent.tools.present? && agent.tools.any? { |tool| Llm::ToolRiskPolicy.mutating?(tool) }
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
