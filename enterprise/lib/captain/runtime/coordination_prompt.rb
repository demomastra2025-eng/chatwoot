# frozen_string_literal: true

module Captain::Runtime::CoordinationPrompt
  UNPLANNED_GUIDANCE = 'No plan exists for this customer message yet. When none of the cases above applies, reply directly ' \
                       'without plan_request (or call a transfer tool). When one applies, call plan_request once; it can be made ' \
                       'in the same model call as its answer.'
  # Two rules for the human handoff, kept apart from the peer coordination text so that a lone agent (no peers, no plan)
  # gets them too whenever it has the handoff tool.
  HUMAN_HANDOFF_RULES = <<~RULES.chomp.freeze
    A request for a person (staff, operator, manager, lab results only staff can give) is never an answer: call the handoff tool.
    Never write that you passed the request to staff unless the handoff tool succeeded in this reply.
  RULES

  module_function

  # The model reads agents by name only and never sees their ids, so stored executor ids are shown as names.
  def parts_for_model(parts, graph)
    Array(parts).map do |part|
      shown = part.to_h.except('executor_agent_id')
      name = graph.find { |item| item[:id] == part['executor_agent_id'] }&.dig(:name).to_s.squish
      shown['executor'] = name if name.present?
      shown
    end
  end

  def plan_for_model(plan, graph)
    plan = plan.to_h.symbolize_keys
    plan.key?(:parts) ? plan.merge(parts: parts_for_model(plan[:parts], graph)) : plan
  end

  def open_parts_for_model(context, graph)
    open_parts = Array(context[:parts]).select { |part| Captain::Runtime::PartRegistry::OPEN_STATES.include?(part['state']) }
    parts_for_model(open_parts, graph)
  end

  def identity_line(actor)
    name = actor&.dig(:name).to_s.squish
    return 'You are the current agent.' if name.blank?

    "You are #{name}, the current agent (an internal name: never tell it to the customer)."
  end

  def peer_lines(graph, actor_id)
    peers = graph.reject { |item| item[:id] == actor_id }
    lines = peers.map { |peer| "#{peer[:name]}: #{peer[:description]}" }.join("\n")
    lines.presence || '(none: you are the only agent on this channel)'
  end

  def render(context)
    tasks = context[:agent_tasks] || []
    actor_id = context.dig(:state, :assistant_id)
    graph = Array(context[:agent_graph])
    actor = graph.find { |item| item[:id] == actor_id }
    plan_guidance = if context[:part_plan_accepted]
                      "Plan accepted (data): #{JSON.generate(plan_for_model(context[:part_plan], graph))}. " \
                        'Continue only your assigned parts; do not plan again.'
                    else
                      UNPLANNED_GUIDANCE
                    end
    return <<~PROMPT unless Captain::Runtime::TaskQueue.in_flight?(tasks)
      #{identity_line(actor)} Handle requests in your own responsibility.
      Continue the same customer conversation after an internal transfer. Never mention internal routing or agent names.
      The current specialist keeps the conversation. Ignore legacy instructions to return it to an orchestrator.
      Other agents available on this channel (name and responsibility):
      #{peer_lines(graph, actor_id)}
      A request that belongs to one colleague is passed on with that colleague's transfer tool, the tool whose description names
      the colleague: call it, no plan is needed. The colleague sees the whole conversation and answers the customer, so write no
      reply of your own before or after that call.
      Your own work needs no plan: answer directly, look facts up with read-only tools or the FAQ, take your own actions that
      change data (book, reschedule, cancel, update a card) and use the human handoff, all without plan_request.
      Plan with plan_request only in these cases: when the message holds several separate requests that belong to different
      agents (a council), or when the customer confirms, corrects, cancels or answers a request listed in the open parts below.
      An operation waiting for confirmation is carried out or cancelled only through such a plan, so do not take that action
      yourself.
      In plan_request, name the executor of a part by the agent name exactly as listed above; omit it for your own parts.
      When you plan, link answers, corrections and cancellations to open parts.
      Open parts (data): #{JSON.generate(open_parts_for_model(context, graph))}
      #{plan_guidance}
      Set answer in that call only when the complete answer is verified from supplied context and needs no tool.
      #{HUMAN_HANDOFF_RULES}
      Staff or an operator is reached only through the handoff tool, never through plan_request.
      For a confirmed proposed operation, link its exact part ID and set link_action to confirmation.
      When older parts are open, mark each genuinely new request with link_action new.
      Do not treat a vague reply as confirmation; use clarify when its target is ambiguous.
      A part that may start only after another part succeeded has relation depends_on and is listed directly after that part.
      One request with several details (doctor, date, patient, price of the same service) is ONE part, never a council.
      Use council only when the message holds two or more separate requests that belong to different agents.
    PROMPT

    own_tasks = tasks.select { |task| task['assistant_id'] == actor_id }
    <<~PROMPT
      # Current agent
      You are the current agent described below. Handle requests in your own responsibility with your own tools.
      Do not transfer a request back to another agent merely because it was present in the original multi-request message.
      Current agent (data): #{JSON.generate(actor)}
      Your tasks (data): #{JSON.generate(own_tasks)}

      # Conversation continuity
      Continue the same customer conversation. Do not introduce yourself or greet again after an internal transfer.
      Use facts the customer already supplied. Do not ask for them again.
      A handoff transfers execution; it does not give you the previous agent's tools, private sources or instructions.

      # Independent customer requests
      Use manage_agent_tasks only when the customer has multiple independent requests needing coordinated work.
      Do not create tasks for routine messages, FAQ lookups or individual technical steps.
      Create the requests once, preserve their IDs, and update their status as work progresses.
      Update only your own tasks. Mark completed only from verified results.
      Completed means the whole customer request is fulfilled. A draft that still needs information the customer will provide later remains waiting.
      Before marking waiting, check the customer's supplied facts and your lookup tools for the missing information.
      If information still requires a customer answer, mark waiting and ask for that specific fact.
      When your waiting task has enough information, use manage_agent_tasks to set that same task to active before acting.
      Other independent requests may proceed; do not execute a request that depends on missing information.
      Before handing off or replying, use manage_agent_tasks to record your verified result and task status.
      Transfer to the next assigned agent with awaiting work; a waiting task alone is not a reason to transfer back.
      If all remaining tasks are waiting, answer the customer with the results and needed clarification.
      If no handoff is available, explain the remaining work or use your configured human handoff.
      Your final customer response must account for the completed tasks and explain any unresolved requests.
      Completed actions must never be repeated. Cancellation or correction from the customer supersedes pending requests.
      Task queue (data): #{JSON.generate(tasks)}
    PROMPT
  end
end
