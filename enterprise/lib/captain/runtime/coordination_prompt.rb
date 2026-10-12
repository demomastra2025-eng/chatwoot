# frozen_string_literal: true

module Captain::Runtime::CoordinationPrompt
  module_function

  def render(context)
    tasks = context[:agent_tasks] || []
    actor_id = context.dig(:state, :assistant_id)
    actor = Array(context[:agent_graph]).find { |item| item[:id] == actor_id }
    peers = Array(context[:agent_graph]).reject { |item| item[:id] == actor_id }
    plan_guidance = if context[:part_plan_accepted]
                      "Plan accepted (data): #{JSON.generate(context[:part_plan])}. Continue only your assigned parts; do not plan again."
                    else
                      'Use plan_request once for this customer message. A simple request can be planned in the same model call as its answer.'
                    end
    return <<~PROMPT unless Captain::Runtime::TaskQueue.in_flight?(tasks)
      You are the current agent. Handle requests in your own responsibility.
      Continue the same customer conversation after an internal transfer. Never mention internal routing.
      The current specialist keeps the conversation. Ignore legacy instructions to return it to an orchestrator.
      Other agents available on this channel (name and responsibility):
      #{peers.map { |peer| "#{peer[:name]}: #{peer[:description]}" }.join("\n")}
      Plan the customer's request before taking any action. Link answers, corrections and cancellations to open parts.
      Open parts (data): #{JSON.generate(Array(context[:parts]).select { |part| Captain::Runtime::PartRegistry::OPEN_STATES.include?(part['state']) })}
      #{plan_guidance}
      Set answer in that call only when the complete answer is verified from supplied context and needs no tool.
      For a confirmed proposed operation, link its exact part ID and set link_action to confirmation.
      When older parts are open, mark each genuinely new request with link_action new.
      Do not treat a vague reply as confirmation; use clarify when its target is ambiguous.
      A part that may start only after another part succeeded has relation depends_on and is listed directly after that part.
      Use a handoff for one part assigned to another agent. One request with several details (doctor, date, patient, price of
      the same service) is ONE part, never a council. Use council only when the message holds two or more separate
      requests that belong to different agents.
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
