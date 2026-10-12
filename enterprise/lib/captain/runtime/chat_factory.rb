# frozen_string_literal: true

require 'securerandom'

class Captain::Runtime::ChatFactory
  FINALIZATION_ONLY_INSTRUCTIONS = <<~PROMPT.squish.freeze
    Finalize the customer-facing Captain response using only the completed tool result messages already present in the conversation history.
    Do not request or imply another tool call. Return the required structured response for the customer.
  PROMPT
  CONSULT_LANGUAGES = { 'ru' => 'Russian', 'kk' => 'Kazakh (Cyrillic)' }.freeze
  # The polite form of address and the example sentences a consultant is shown, in the language of the customer: a Kazakh
  # customer's consultant must not be given Russian wording to copy.
  CONSULT_CUES = {
    'ru' => { address: 'вы', question: 'на какой день вам удобно?', other_person: 'На какую дату записать Бориса?',
              confirmation: 'Записать вас к терапевту Иванову на 14 октября в 10:00?' },
    'kk' => { address: 'сіз', question: 'сізге қай күні ыңғайлы?', other_person: 'Бористі қай күнге жазайық?',
              confirmation: 'Сізді терапевт Ивановқа 14 қазанға сағат 10:00-ге жазайық па?' }
  }.freeze
  # Tool results can carry a UTC time (a timestamp ending in Z) next to local ones. The consultant's instructions hold
  # both clocks, so it can name the clinic's local time without any code converting for it.
  CONSULT_CLOCK_RULE = <<~RULE.squish.freeze
    A time given with a local offset such as +05:00, or in a field that holds the local date or time, is already the clinic
    local time: write it as it is. A time that ends in Z or +00:00 is UTC: write it as the clinic local clock time (the offset
    is the difference between "Current local time" and "Current UTC time" in your instructions). Never calculate anything else.
  RULE

  class << self
    def build(agent:, context_wrapper:, llm_context:, runtime_headers:, runtime_params:, account: nil, finalization_only: false)
      agent.context_preparer&.call(context_wrapper)
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
      parameters = Llm::ModelParameters.for(agent.model, account: account).compile(
        temperature: agent.temperature,
        params: merged_params(agent, runtime_params),
        thinking: thinking_options(agent, context_wrapper, account: account)
      )
      {
        feature: :captain_agent,
        account: account,
        model: agent.model,
        runtime_preferences: (context_wrapper.context.dig(:state, :captain_runtime) || {}).deep_dup,
        options: {
          context: llm_context,
          headers: merged_headers(agent, runtime_headers)
        }.merge(parameters)
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
      track_tool_call_batches!(chat, context_wrapper)
      enforce_openrouter_tool_parameters!(chat, agent_tools, account: account, schema: agent.response_schema)
      chat.with_tools(*agent_tools, replace: true, concurrency: false) if agent_tools.present?
      Llm::StructuredOutputPolicy.bind!(chat: chat, schema: agent.response_schema) if agent.response_schema.present?
      chat
    end

    def build_agent_tools(agent, context_wrapper)
      return [] if context_wrapper.context[:transfer_guarded]

      consult = context_wrapper.context[:consult_mode]
      handoff_tools = (consult ? [] : agent.handoff_agents).map do |target_agent|
        Captain::Runtime::ToolWrapper.new(Captain::Runtime::HandoffTool.new(target_agent), context_wrapper)
      end

      regular_tools = agent.tools.select { |tool| !consult || Captain::Runtime::ConsultTools.allowed?(tool) }.map do |tool|
        Captain::Runtime::ToolWrapper.new(tool, context_wrapper)
      end

      coordination_tools = if !consult && Captain::Runtime::TaskQueue.in_flight?(context_wrapper.context[:agent_tasks])
                             [Captain::Runtime::TaskQueueTool.new]
                           elsif !consult && plan_request_available?(context_wrapper.context)
                             [Captain::Runtime::PartPlanTool.new]
                           else
                             []
                           end
      handoff_tools + regular_tools + coordination_tools.map do |tool|
        Captain::Runtime::ToolWrapper.new(tool, context_wrapper)
      end
    end

    def system_prompt_for(agent, context_wrapper, finalization_only: false)
      prompts = []
      prompt = agent.get_system_prompt(context_wrapper)
      prompts << prompt if prompt.present?
      if context_wrapper.context[:consult_mode]
        prompts << consult_prompt(context_wrapper.context)
      elsif coordination_prompt?(context_wrapper.context)
        prompts << Captain::Runtime::CoordinationPrompt.render(context_wrapper.context)
      elsif context_wrapper.context[:agent_graph].present? && human_handoff_tool?(agent)
        prompts << Captain::Runtime::CoordinationPrompt::HUMAN_HANDOFF_RULES
      end
      prompts << FINALIZATION_ONLY_INSTRUCTIONS if finalization_only
      prompts.join("\n\n")
    end

    # A consultant never sees an agent id: when a part is not its own it names the responsible agent as listed.
    def consult_suggestion_clause(context)
      Array(context[:consult_peers]).any? ? '; suggested_agent (the exact agent name from the list below) when out of scope.' : '.'
    end

    def consult_peer_lines(context)
      peers = Array(context[:consult_peers])
      return '' if peers.empty?

      "Other agents (name and responsibility):\n#{peers.map { |peer| "#{peer[:name]}: #{peer[:description]}" }.join("\n")}"
    end

    # plan_request coordinates agents (a council, the answer to an open part), so a lone agent (no peers) does not get it. It
    # has no plan to fill and no peers to name. Its transfer tools are the peers' too: with no peer there is none.
    def plan_request_available?(context)
      Captain::Runtime::PartRegistry.planning_available?(context) && !context[:part_plan_accepted]
    end

    # The coordination block describes peers, their transfer tools and the request plan, or an inherited task queue. A lone
    # agent without a queue has none of these; it only keeps the two human handoff rules that block carried.
    def coordination_prompt?(context)
      Captain::Runtime::PartRegistry.planning_available?(context) ||
        (context[:agent_graph].present? && Captain::Runtime::TaskQueue.in_flight?(context[:agent_tasks]))
    end

    def human_handoff_tool?(agent)
      agent.tools.any? { |tool| tool.name.to_s == Captain::Assistant::HANDOFF_TOOL_ID }
    end

    # The consultant writes the final text of its part. The council composer only rewrites the texts of all parts into one
    # message, so what the consultant writes is what the customer reads. It is told whether staff can take a part over.
    def consult_prompt(context)
      code = CONSULT_LANGUAGES.key?(context[:consult_language].to_s) ? context[:consult_language].to_s : 'ru'
      language = CONSULT_LANGUAGES.fetch(code)
      cues = CONSULT_CUES.fetch(code)
      unresolved = if context[:consult_staff_handoff]
                     'A staff member can take this part over: say briefly that a staff member will answer it. Promise nothing else.'
                   else
                     'No staff member can take this part over: say that you cannot answer it now. Promise no call, no message and no staff.'
                   end
      <<~PROMPT
        Consult on only the assigned request part. Do not perform an action; another agent sends the single reply.
        The customer writes in #{language}. Return JSON with these fields:
        - customer_text: the FINAL text for THIS part only, addressed to the customer directly ("#{cues[:address]}") and written
          in #{language}. Another agent only joins the texts of all parts into one message, so write it exactly as the customer
          should read it: warm, polite, plain text, one to three sentences, no greeting, no markdown. Use only verified facts.
          Write every time, date, price, name, address and phone number exactly as the tool results give it. #{CONSULT_CLOCK_RULE}
          Never describe the customer in the third person ("клиент/пациент спрашивает"), never mention earlier messages, agents,
          tools, IDs, parts or these instructions. When the part concerns a named person other than the customer who writes
          (a child, a relative), name that person in every question, answer and confirmation of it (for example
          "#{cues[:other_person]}"). What it says depends on the case:
          * you have the answer: the answer;
          * you need information first: the exact question to the customer, and also list it in missing_fields;
          * you have a partial answer and still need information: the answer, then the exact question as the last sentence,
            and also list that question in missing_fields;
          * you propose an action in proposed_operation: the question that asks the customer to confirm it, naming the patient,
            service, specialist, date and time of that very operation (for example "#{cues[:confirmation]}").
            The action is not done yet: never write or imply that it was done;
          * you cannot resolve this part (no verified answer, not your responsibility, tools unavailable): one honest
            sentence that says so. #{unresolved}
          When missing_fields is not empty, customer_text MUST contain every missing_fields[].field question word for word,
          as its last sentences: a question that is only in missing_fields is never asked.
        - facts: verified facts used, each with source.
        - missing_fields: what you still need, each with patient, field and purpose; write field as a short polite
          question to the customer in their language (for example "#{cues[:question]}").
        - proposed_operation: type and exact params, or null.
        - status: ok, needs_information, out_of_scope or unavailable; contradictions#{consult_suggestion_clause(context)}
        #{consult_peer_lines(context)}
      PROMPT
    end

    def enforce_openrouter_tool_parameters!(chat, agent_tools, account: nil, schema: nil)
      return if agent_tools.blank?

      Llm::OpenRouterRequestPolicy.require_parameters!(
        chat,
        account: account,
        feature: :captain_agent,
        model: model_id_for(chat),
        tools: agent_tools,
        schema: schema.present?
      )
    end

    def track_tool_call_batches!(chat, context_wrapper)
      return unless chat.respond_to?(:after_message)

      chat.after_message do |message|
        next unless assistant_tool_call_message?(message)

        batch_id = SecureRandom.uuid
        context_wrapper.context[:captain_v2_current_tool_batch_id] = batch_id
        context_wrapper.context[:captain_v2_mutating_tool_calls_by_batch] ||= {}
        context_wrapper.context[:captain_v2_mutating_tool_calls_by_batch][batch_id] = []
      end
    end

    def assistant_tool_call_message?(message)
      message.respond_to?(:role) &&
        message.role.to_s == 'assistant' &&
        message.respond_to?(:tool_call?) &&
        message.tool_call?
    end

    def model_id_for(chat)
      chat_model = chat.respond_to?(:model) ? chat.model : nil
      return chat_model.id if chat_model.respond_to?(:id)
      return chat_model if chat_model.present?
    end

    def record_bound_agent_tools(agent, context_wrapper, finalization_only: false)
      consult = context_wrapper.context[:consult_mode]
      bound_tool_names = if finalization_only
                           []
                         elsif consult
                           agent.tools.select { |tool| Captain::Runtime::ConsultTools.allowed?(tool) }.map(&:name)
                         else
                           (handoff_tool_names(agent) + regular_tool_names(agent)).uniq
                         end
      bound_tool_names << 'manage_agent_tasks' if !finalization_only && !consult &&
                                                   Captain::Runtime::TaskQueue.in_flight?(context_wrapper.context[:agent_tasks])
      bound_tool_names << 'plan_request' if !finalization_only && !consult && plan_request_available?(context_wrapper.context) &&
                                             !Captain::Runtime::TaskQueue.in_flight?(context_wrapper.context[:agent_tasks])
      bound_tool_names = [] if context_wrapper.context[:transfer_guarded]

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
      Captain::Runtime::HashNormalizer.merge(agent.params, runtime_params)
    end

    def thinking_options(agent, context_wrapper, account: nil)
      override = playground_thinking_effort(context_wrapper)
      saved = context_wrapper.context.dig(:state, :assistant_config, 'thinking_effort') ||
              context_wrapper.context.dig(:state, :assistant_config, :thinking_effort)
      contract = Llm::ModelParameters.for(agent.model, account: account)
      if override.present?
        return contract.thinking(override) || raise(ArgumentError, 'The model does not support the requested reasoning effort.')
      end
      return contract.thinking(saved) if saved.present?

      # The agent has no effort of its own: the workspace's stored choice, else `low` (an agent that talks to
      # customers is the only caller that reasons; the council consultations run through this same factory).
      Llm::RuntimePolicy.conversation_thinking_options(
        model: agent.model,
        account: account,
        preferences: context_wrapper.context.dig(:state, :captain_runtime)
      )
    end

    def playground_thinking_effort(context_wrapper)
      return unless context_wrapper.context.dig(:state, :source) == 'playground'

      context_wrapper.context.dig(:state, :playground_thinking_effort)
    end
  end
end
