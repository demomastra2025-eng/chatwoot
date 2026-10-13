# frozen_string_literal: true

# The block ChatFactory appends to the system prompt of an agent that has colleagues on its channel: who they are, how to work
# with them, and the data of the conversation that coordination needs. Short English text for the model; the data blocks
# (open parts, outcomes the patient has not been told) appear only when they have something in them. The human handoff rules are
# not part of it: the platform rules of the main prompt carry them.
module Captain::Runtime::CoordinationPrompt
  WORKING_TOGETHER = <<~RULES.chomp.freeze
    How to work together:
    1. Split the patient's latest message into separate requests. A service's price, its free times and its booking are one request for the agent that books it.
    2. Answer questions yourself: every agent can use the FAQ and the catalog.
    3. If the message asks for an action you cannot do (book, reschedule, cancel, a deal...), transfer the conversation to the colleague whose tools can do it; that colleague also answers the questions of the message.
    4. If the message holds actions for two or more different agents, call plan_request once to split it; each agent does its part right away.
    5. Staff are reached through handoff.
  RULES
  TRANSFERRED_RULE = 'The conversation was transferred to you: the whole message is yours unless it holds a separate request for another colleague.'
  OPEN_PARTS_RULE = 'Link a message to an open part, by its number, with plan_request only when the message answers, corrects or cancels ' \
                    'that part (for a part that waits for the patient: when it answers the question shown). Every other message is a new request.'
  PLAN_ACCEPTED_RULE ='The plan for this message is already accepted: continue only your own parts and do not call plan_request again.'
  MENTION_IT = 'Mention it in your reply.'
  FRAGMENT_LIMIT = 200
  QUESTION_LIMIT = 600
  PATIENT_LIMIT = 80

  module_function

  # The name of an agent the model sees. It never sees an id.
  def name_of(graph, agent_id)
    graph.find { |item| item[:id] == agent_id }&.dig(:name).to_s.squish.presence
  end

  def render(context)
    tasks = context[:agent_tasks] || []
    actor_id = context.dig(:state, :assistant_id)
    graph = Array(context[:agent_graph])
    actor = graph.find { |item| item[:id] == actor_id }
    return task_queue_block(actor, tasks) if Captain::Runtime::TaskQueue.in_flight?(tasks)

    peers = graph.reject { |item| item[:id] == actor_id }
    return '' if peers.empty?

    [colleagues_block(actor, peers, context), open_parts_block(context, graph), accepted_plan_block(context, graph),
     done_block(context)].compact_blank.join("\n\n")
  end

  # The colleagues, then the numbered way of working. The rule for a transferred conversation closes the list, and only a run
  # in which the conversation was transferred to this agent has it. After the transfer guard the agent has no transfer and no plan
  # tool any more (see ChatFactory.build_agent_tools): the way of working that calls them is left out, the list of colleagues stays.
  def colleagues_block(actor, peers, context)
    name = actor&.dig(:name).to_s.squish.tr('"', "'")
    identity = [(%(You are "#{name}";) if name.present?), 'you and your colleagues answer as one clinic.'].compact.join(' ').upcase_first
    rules = [WORKING_TOGETHER, (TRANSFERRED_RULE if context[:handoff_count].to_i.positive?)] unless context[:transfer_guarded]
    ['# Colleagues on this channel', identity, *peers.map { |peer| peer_line(peer) }, *rules].compact.join("\n")
  end

  def peer_line(peer)
    "- #{[peer[:name], peer[:description]].map { |text| text.to_s.squish }.compact_blank.join(': ')}"
  end

  # One row per part of ANOTHER agent that is still open: its number (the plan links by it), who handles it, what it is and where
  # it stands (see PartRegistry.listed_parts). The delivered texts, the object references and every id stay out. The rule that
  # links a message to a part calls plan_request, so it is left out once the plan of this message is accepted or the transfer guard
  # took the plan tool away (plan_request is no longer bound then): only the rows stay.
  def open_parts_block(context, graph)
    parts = Array(context[:parts])
    open_parts = Captain::Runtime::PartRegistry.listed_parts(context)
    return '' if open_parts.empty?

    rows = open_parts.map { |part| "- #{open_part_segments(parts, part, graph).compact_blank.join(' · ')}" }
    rule = OPEN_PARTS_RULE unless context[:part_plan_accepted] || context[:transfer_guarded]
    ['# Open parts (data)', *rows, rule].compact.join("\n")
  end

  def open_part_segments(parts, part, graph)
    patient = part['patient'].to_s.squish
    [
      "##{Captain::Runtime::PartRegistry.number_of(parts, part['id'])}",
      name_of(graph, part['executor_agent_id']),
      quoted(part['fragment']),
      (patient.present? && patient != 'unknown' ? "for #{patient.first(PATIENT_LIMIT)}" : nil),
      part_state(part)
    ]
  end

  # Where an open part stands. A part that waits for the patient shows the question it asked.
  def part_state(part)
    return 'unresolved' if part['state'] == 'unknown'
    return 'open' unless part['state'] == 'waiting_customer'

    question = Array(part['missing_fields']).join(' ').squish.presence || part['summary'].to_s.squish
    question.present? ? "waiting for the patient: #{quoted(question, QUESTION_LIMIT)}" : 'waiting for the patient'
  end

  # A plan that was already accepted for this message: the agent whose prompt is built again (a retry, a rebuilt chat) continues
  # its parts and has no plan_request to call any more. One row per part: who handles it and what it is, by name and quoted
  # fragment only (no ids, versions, delivered texts or other stored fields).
  def accepted_plan_block(context, graph)
    return '' unless context[:part_plan_accepted]

    rows = Array(context.dig(:part_plan, :parts)).filter_map do |part|
      row = [name_of(graph, part['executor_agent_id']), (quoted(part['fragment']) if part['fragment'].present?)].compact.join(' · ')
      "- #{row}" if row.present?
    end
    [('# Accepted plan (data)' if rows.any?), *rows, PLAN_ACCEPTED_RULE].compact.join("\n")
  end

  # What specialists did in an earlier run whose reply never reached the patient.
  def done_block(context)
    outcomes = Captain::Runtime::PartRegistry.undelivered_outcomes(context[:parts]).map { |part| outcome_text(part) }
    return '' if outcomes.empty?

    ['# Done, not yet told to the patient (data)', *outcomes.map { |text| "- #{text} #{MENTION_IT}" }].join("\n")
  end

  def outcome_text(part)
    text = part['summary'].to_s.squish.presence || "An action was done for the request #{quoted(part['fragment'])}"
    text.match?(/[.!?…]\z/) ? text : "#{text}."
  end

  # Patient words as a quoted data string: JSON keeps a quote or a line break in them from ending the row.
  def quoted(text, limit = FRAGMENT_LIMIT)
    JSON.generate(text.to_s.squish.first(limit))
  end

  # An inherited task queue (an older conversation that still has unfinished tasks) replaces the colleagues block.
  def task_queue_block(actor, tasks)
    own_tasks = tasks.select { |task| task['assistant_id'] == actor&.dig(:id) }
    <<~PROMPT.chomp
      # Current agent
      You are the current agent below. Handle your own tasks with your own tools; do not transfer a request back only because it was in the original multi-request message.
      Current agent (data): #{JSON.generate(actor)}
      Your tasks (data): #{JSON.generate(own_tasks)}

      # Task queue
      Continue the same conversation: do not greet or introduce yourself again, and use the facts the patient already gave.
      Use manage_agent_tasks to record your verified result and status before you reply or transfer; update only your own tasks.
      - completed: the whole request is done. waiting: a patient answer is still missing, so ask for what is still missing in one message; when it is known, set the task to active before acting.
      - Transfer only to an agent that has awaiting work; a waiting task alone is no reason to transfer back. When every remaining task is waiting, answer with the results and the needed question.
      - Never repeat a completed action. A cancellation or correction from the patient replaces pending requests.
      - Your final reply covers the completed tasks and explains any unresolved request.
      Task queue (data): #{JSON.generate(tasks)}
    PROMPT
  end
end
