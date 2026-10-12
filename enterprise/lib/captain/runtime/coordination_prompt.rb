# frozen_string_literal: true

# The block ChatFactory appends to the system prompt of an agent that has colleagues on its channel: who they are, how to work
# with them, and the data of the conversation that coordination needs. Short English text for the model; the data blocks
# (open parts, outcomes the patient has not been told) appear only when they have something in them. The human handoff rules are
# not part of it: the platform rules of the main prompt carry them.
module Captain::Runtime::CoordinationPrompt
  INTERNAL_NAMES = 'Agent names are internal: never tell them to the patient and never mention transfers.'
  WORKING_TOGETHER = <<~RULES.chomp.freeze
    How to work together:
    - Do your own work yourself, without a plan: answer, look things up, book, reschedule, cancel.
    - If the whole request belongs to one colleague, call that colleague's transfer tool and write nothing yourself: the colleague sees the whole conversation and replies.
    - If one message holds several separate requests for different agents, call plan_request once and split them into parts (a council). Each agent does its own part right away with its own tools.
    - One request with details (doctor, date, patient, price of the same service) is one part, not a council.
    - Staff are reached only through handoff, never through a plan.
  RULES
  OPEN_PARTS_RULE = 'If the patient answers, corrects or cancels an open part, call plan_request and link the message only to that part ' \
                    'by its number: its agent continues it. If the part is yours, link it with mode answer_myself.'
  PLAN_ACCEPTED_RULE = 'The plan for this message is already accepted: continue only your own parts and do not call plan_request again.'
  MENTION_IT = 'Mention it in your reply.'
  FRAGMENT_LIMIT = 200
  QUESTION_LIMIT = 600
  PATIENT_LIMIT = 80

  module_function

  # The name of an agent the model sees. It never sees an id.
  def name_of(graph, agent_id)
    graph.find { |item| item[:id] == agent_id }&.dig(:name).to_s.squish.presence
  end

  # The model reads agents by name only and never sees their ids, so stored executor ids are shown as names.
  def parts_for_model(parts, graph)
    Array(parts).map do |part|
      shown = part.to_h.except('executor_agent_id')
      name = name_of(graph, part['executor_agent_id'])
      shown['executor'] = name if name.present?
      shown
    end
  end

  def plan_for_model(plan, graph)
    plan = plan.to_h.symbolize_keys
    plan.key?(:parts) ? plan.merge(parts: parts_for_model(plan[:parts], graph)) : plan
  end

  def render(context)
    tasks = context[:agent_tasks] || []
    actor_id = context.dig(:state, :assistant_id)
    graph = Array(context[:agent_graph])
    actor = graph.find { |item| item[:id] == actor_id }
    return task_queue_block(actor, tasks) if Captain::Runtime::TaskQueue.in_flight?(tasks)

    peers = graph.reject { |item| item[:id] == actor_id }
    return '' if peers.empty?

    [colleagues_block(actor, peers), open_parts_block(context, graph), accepted_plan_block(context, graph),
     done_block(context)].compact_blank.join("\n\n")
  end

  def colleagues_block(actor, peers)
    name = actor&.dig(:name).to_s.squish
    identity = name.present? ? %(You are "#{name.tr('"', "'")}". #{INTERNAL_NAMES}) : INTERNAL_NAMES
    ['# Colleagues on this channel', identity, *peers.map { |peer| peer_line(peer) }].join("\n") + "\n\n#{WORKING_TOGETHER}"
  end

  def peer_line(peer)
    description = peer[:description].to_s.squish
    description.present? ? "- #{peer[:name].to_s.squish}: #{description}" : "- #{peer[:name].to_s.squish}"
  end

  # One row per part that is still open: its number (the plan links by it), who handles it, what it is and where it stands. The
  # delivered texts, the object references and every id stay out.
  def open_parts_block(context, graph)
    parts = Array(context[:parts])
    open_parts = parts.select { |part| Captain::Runtime::PartRegistry::OPEN_STATES.include?(part['state']) }
    return '' if open_parts.empty?

    rows = open_parts.map { |part| "- #{open_part_segments(parts, part, graph).compact_blank.join(' · ')}" }
    ['# Open parts (data)', *rows, OPEN_PARTS_RULE].join("\n")
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
    case part['state']
    when 'waiting_customer'
      question = Array(part['missing_fields']).join(' ').squish.presence || part['summary'].to_s.squish
      question.present? ? "waiting for the patient: #{quoted(question, QUESTION_LIMIT)}" : 'waiting for the patient'
    when 'unknown' then 'unresolved'
    else 'open'
    end
  end

  # A plan that was already accepted for this message: the agent whose prompt is built again (a retry, a rebuilt chat) continues
  # its parts and has no plan_request to call any more.
  def accepted_plan_block(context, graph)
    return '' unless context[:part_plan_accepted]

    ['# Accepted plan (data)', JSON.generate(plan_for_model(context[:part_plan], graph)), PLAN_ACCEPTED_RULE].join("\n")
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
      - completed: the whole request is done. waiting: a patient answer is still missing, so ask for that one fact; when it is known, set the task to active before acting.
      - Transfer only to an agent that has awaiting work; a waiting task alone is no reason to transfer back. When every remaining task is waiting, answer with the results and the needed question.
      - Never repeat a completed action. A cancellation or correction from the patient replaces pending requests.
      - Your final reply covers the completed tasks and explains any unresolved request.
      Task queue (data): #{JSON.generate(tasks)}
    PROMPT
  end
end
