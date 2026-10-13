# frozen_string_literal: true

# A council: one customer message that holds separate requests for different agents, or the answer to an open part of another
# agent. Every part is a normal run of the agent that OWNS it (see Council::PartRun), with that agent's own tools, mutating tools
# included: the owner books, moves or cancels as soon as it has what it needs, otherwise it asks for everything still missing in one message, and it
# writes the final text of its part from what its tools returned. The editor (CouncilEditor) only merges the part texts into one
# message; a council of one part sends that text as it is. The conversation never changes hands.
#
# Threads. Every mutating tool runs on the thread of the job (it carries the user, the delivery policy of a Playground run, the
# locale and the durable session). The parts whose owners can write form ONE lane that runs there in plan order; read-only
# parts run on threads of their own, side by side with it (see Council::Lanes). Only the calling thread touches the shared
# context and the registry: threads return plain data that the calling thread records after the join.
#
# The runtime writes no sentence to the customer. A part tells the customer only what its owner wrote: a part without a text of
# its own is left out of the reply, also when it acted (staff get a private note, see #staff_note) and also when it could not be
# resolved (the conversation goes to staff after the reply). A technical failure of a tool (see ToolFailure) stops the part: it is
# not mentioned to the customer, the other parts are answered, and the conversation goes to staff after the reply
# (council_handoff, technical: true). When no part has a text, the reply is empty and the run sends nothing.
class Captain::Runtime::Council
  UNRESOLVED_STATES = %w[open unknown].freeze
  HANDOFF_REASON = 'council_unresolved'
  TECHNICAL_HANDOFF_REASON = 'council_technical_failure'
  PART_SEPARATOR = "\n\n"
  # A booking is: find the resource, the service and the slot, read the contact, create, verify. ToolLoopGuard allows 16 tool requests.
  PART_MAX_TURNS = 14
  THREAD_LIMIT = [ENV.fetch('CAPTAIN_COUNCIL_THREADS', 4).to_i, 1].max
  # Read-only lanes on threads, process-wide. A lane that gets no slot runs on the calling thread.
  SLOTS = Concurrent::Semaphore.new(THREAD_LIMIT)
  # Turns the threads off at once (ENV or an InstallationConfig row set to off, 0, false, disabled or no): every part runs
  # in plan order on the calling thread. The routing benchmark and the specs that share one database connection run like this.
  PARALLEL_SWITCH = 'CAPTAIN_COUNCIL_PARALLEL'
  MAX_COMPLETED_TOOL_RESULT_RECORDS = 50
  # Keys of the run state of the main run. A part starts with none of them: it has its own tool caches, counters and tool gate.
  RUN_STATE_KEYS = [
    :captain_v2_tool_result_cache, :captain_v2_tool_failure_cache, :captain_v2_tool_attempt_counts,
    :captain_v2_mutating_tool_executions, :captain_v2_current_tool_batch_id, :captain_v2_mutating_tool_calls_by_batch,
    :captain_v2_bound_tool_ids, :captain_v2_bound_tool_ids_by_agent, :captain_v2_bound_tool_gate, :captain_v2_completed_tool_names,
    :captain_v2_completed_tool_results, :captain_v2_completed_actions, :captain_v2_service_specific_scheduling, :captain_faq_outcome,
    :captain_v2_handoff_tool_called,
    :pending_handoff, :pending_human_handoff, :pending_response_cancellation, :handoff_count, :previous_handoff_source_id,
    :part_plan, :part_plan_refused, :part_plan_processed, :transfer_guard, :transfer_guard_active, :transfer_guarded,
    :technical_failure, :council_handoff, :council_note, :council_untold_part_ids, :council_contributors, :__otel_tracing,
    :__llm_event_bus,
    Captain::Runtime::ToolLoopGuard::REQUEST_COUNTS_KEY, Captain::Runtime::ToolLoopGuard::TERMINAL_STOP_KEY,
    Captain::Runtime::TracingCallbacks::TRACE_EVENT_CONTEXT_KEY
  ].freeze
  # What a part must not hold of the main run: its durable session (only a writer gets it back), its graph, queue and plan.
  MAIN_RUN_KEYS = %i[agent_session agent_graph agent_graph_object agent_run_context_object agent_tasks parts].freeze

  # What the council knows about one part before it runs. settled: the stored part of an earlier attempt of the same request.
  Plan = Struct.new(:part, :actor, :agent, :writer, :snapshot, :settled, keyword_init: true) do
    def runnable?
      !actor.nil? && settled.nil?
    end
  end

  class << self
    def parallel?
      Captain::Runtime::CouncilEditor::OFF_VALUES.none? do |off|
        [ENV.fetch(PARALLEL_SWITCH, nil), InstallationConfig.find_by(name: PARALLEL_SWITCH)&.value].any? do |value|
          value.to_s.strip.downcase == off
        end
      end
    rescue StandardError
      true
    end
  end

  # model: the acting agent's runtime model, used by the editor that writes the single customer reply.
  # callbacks: the callbacks of the run, so that the tool calls of the parts are traced like those of any other run.
  def initialize(context:, graph:, account:, llm_context: nil, model: nil, callbacks: nil)
    @context, @graph, @account, @llm_context, @model = context, graph, account, llm_context, model
    @callbacks = callbacks || {}
    @entries = {}
    @results = []
    @participants = []
    @monitor = Monitor.new
    @aborted = Concurrent::AtomicBoolean.new(false)
    @calling_thread = Thread.current
  end

  def run(parts)
    ids = parts.pluck('id')
    @participants = parts.pluck('executor_agent_id').uniq
    Captain::Runtime::CoordinationEvents.council_started(context: @context, participant_ids: @participants, part_ids: ids)
    prime_run_state
    plans = parts.map { |part| prepare_part(part) }
    execute(plans)
    reply = assemble(parts.map { |part| @entries.fetch(part['id']) })
    @context[:council_contributors] = contributors
    Captain::Runtime::CoordinationEvents.council_finished(context: @context, participant_ids: @participants,
                                                           part_ids: ids, outcome: 'assembled')
    reply
  rescue StandardError
    Captain::Runtime::CoordinationEvents.council_finished(context: @context, participant_ids: @participants || [],
                                                           part_ids: ids || [], outcome: 'unavailable')
    raise
  ensure
    merge_tool_tracking
  end

  private

  # What every part is told and what the threads need is read once, on the calling thread, before any thread starts.
  def prime_run_state
    @calling_thread = Thread.current
    customer_message
    reply_language
    staff_handoff_available?
    @peers = Array(@context[:agent_graph])
    @shared_callbacks = serialized(@callbacks)
  end

  # --- Preparing the parts (calling thread) -------------------------------------------------------------------------------

  # A part that was settled by an earlier attempt of the same request (the job retried) is replayed from what was stored and
  # never run again: its tools may already have changed something.
  def prepare_part(part)
    stored = Array(@context[:parts]).find { |item| item['id'] == part['id'] && item['version'].to_i == part['version'].to_i }
    return Plan.new(part: part, settled: stored) if stored && stored['state'] != 'open'

    build_plan(part)
  end

  def build_plan(part)
    actor = fresh_actor(part.fetch('executor_agent_id'))
    return Plan.new(part: part) unless actor

    agent = part_agent(actor)
    writer = agent.tools.any? { |tool| Llm::ToolRiskPolicy.mutating?(tool) }
    Plan.new(part: part, actor: actor, agent: agent, writer: writer, snapshot: part_snapshot(actor, part, writer))
  rescue Captain::Conversation::ControlGenerationStaleError
    raise
  rescue StandardError => e
    Rails.logger.warn("[CAPTAIN][Council] part owner unavailable error_class=#{e.class.name}")
    Plan.new(part: part)
  end

  # The owner's own agent, without the tools that change who controls the conversation and without any handoff target: a part
  # never transfers the conversation. It answers with the structured result of a part.
  def part_agent(actor)
    runtime = actor.agent
    Captain::Runtime::Agent.new(
      name: runtime.name, instructions: runtime.instructions, tools: Captain::Runtime::PartTools.filter(runtime.tools),
      model: runtime.model, temperature: runtime.temperature, headers: runtime.headers, params: runtime.params,
      response_schema: Captain::Runtime::PartSchema
    ).tap { |agent| agent.assistant_id = actor.id }
  end

  def fresh_actor(id)
    entry = Captain::Assistant.find_by(id: @graph.entry.id, account_id: @account.id)
    return unless entry

    Captain::AgentGraph.new(entry, inbox: fresh_inbox).find(id)
  end

  # A record of its own: the agents built here may be used on other threads and must not share the record of the run.
  def fresh_inbox
    shared = @graph.inbox
    (Inbox.find_by(id: shared.id, account_id: @account.id) if shared.respond_to?(:id)) || shared
  end

  def part_snapshot(actor, part, writer)
    snapshot = @context.except(*MAIN_RUN_KEYS, *RUN_STATE_KEYS).deep_dup
    snapshot.merge!(part_run: true, part_plan_accepted: true, active_part_id: part['id'], active_part_version: part['version'],
                    part_language: reply_language, part_staff_handoff: staff_handoff_available?,
                    part_customer_message: customer_message, part_info: part_info(part),
                    part_peers: @peers.reject { |item| item[:id] == actor.id }.map { |item| item.slice(:name, :description) },
                    conversation_history: public_history(@context[:conversation_history]), current_agent: actor.agent_name)
    # The durable session protects the actions of a writer from being repeated. A read-only part has no actions.
    snapshot[:agent_session] = @context[:agent_session] if writer && @context[:agent_session]
    # In the Playground the owner passes the session's checks as itself; the session keeps its active agent.
    playground = @context[:playground_session]
    snapshot[:playground_session] = playground.acting_as(actor.id) if playground.respond_to?(:acting_as)
    part_state(snapshot, actor, part)
    snapshot
  end

  def part_state(snapshot, actor, part)
    state = snapshot[:state] ||= {}
    state[:assistant_id] = actor.id
    state[:assistant_config] = actor.config
    state[:captain_runtime] = Captain::AssistantSafetyPreferences.for(assistant: actor, feature: :assistant)
    effort = actor.config.to_h['thinking_effort']
    state[:captain_runtime]['assistant_thinking_effort'] = effort if effort.present?
    state[:prompt_context] = actor.prompt_context_state(state)
    # The fence keeps the run current (a newer message, a human reply, a status change) but not the routing of the main run,
    # which the part does not follow: its owner is not the acting agent. A run without a fence (a Playground run, a run
    # without a conversation) stays without one: a fence of part ids alone would look for a conversation that is not there.
    fence = state[:captain_response_fence].to_h.with_indifferent_access
    return if fence.blank?

    state[:captain_response_fence] = fence.except(:routing_revision).merge(part_id: part['id'], part_version: part['version'])
  end

  def part_info(part)
    {
      id: part['id'], version: part['version'], patient: part['patient'], relation: part['relation'], fragment: part['fragment'],
      link_action: part['link_action'], prior_summary: prior_conclusion(part), questions: Array(part['prior_questions']).presence,
      prior_acted: part['prior_acted'].presence
    }.compact
  end

  # What an earlier version of the part concluded. A version that ended unresolved (its tools found nothing usable) concluded
  # nothing: its summary is not handed on as a conclusion, so the owner looks again with its own tools.
  def prior_conclusion(part)
    return if part['prior_state'] == 'unknown' && part['prior_acted'] != true

    part['prior_summary'].presence
  end

  def public_history(history)
    Array(history).filter_map do |raw|
      message = raw.to_h.with_indifferent_access
      next unless %w[user assistant].include?(message[:role].to_s)
      next if message[:tool_calls].present?

      content = message[:content]
      if message[:role].to_s == 'assistant'
        parsed = content.is_a?(String) ? JSON.parse(content) : content
        content = parsed['response'].to_s if parsed.is_a?(Hash) && parsed.key?('response')
      end
      { role: message[:role], content: content }
    rescue JSON::ParserError
      nil
    end
  end

  # --- Running the parts ----------------------------------------------------------------------------------------------------

  def execute(plans)
    plans.reject(&:runnable?).each { |plan| record_outcome(plan, immediate_entry(plan), nil) }
    runnable = plans.select(&:runnable?)
    return if runnable.empty?

    inline, threads = schedule(runnable)
    failure = nil
    begin
      inline.each { |lane| run_lane(lane) { |plan, entry, result| record_outcome(plan, entry, result) } }
    rescue Captain::Conversation::ControlGenerationStaleError => e
      failure = e
    ensure
      # Every thread is always joined, also when the calling thread failed: a thread must never outlive the run.
      outcomes = join(threads)
    end
    raise failure if failure

    settle_threads(outcomes)
    reassign_pass(plans)
  end

  # [lanes that run on the calling thread, [lane, thread] pairs]. The writer lane stays on the calling thread; every read-only
  # lane gets a thread while there are slots. With the threads switched off everything is one lane in plan order.
  def schedule(runnable)
    return [[runnable], []] unless self.class.parallel?

    lanes = Captain::Runtime::Council::Lanes.build(runnable.map { |plan| lane_plan(plan) })
    by_id = runnable.index_by { |plan| plan.part['id'] }
    inline = []
    inline << lanes[:writer].map { |item| by_id.fetch(item.id) } if lanes[:writer].any?
    threads = []
    lanes[:readers].each do |readers|
      lane = readers.map { |item| by_id.fetch(item.id) }
      thread = start_thread(lane)
      thread ? threads << [lane, thread] : inline << lane
    end
    [inline, threads]
  end

  def lane_plan(plan)
    part = plan.part
    prerequisite = part['depends_on_part_id'] if %w[depends_on conditional].include?(part['relation'])
    Captain::Runtime::Council::Lanes::Plan.new(id: part['id'], writer: plan.writer, prerequisite_id: prerequisite,
                                               object_refs: part['object_refs'])
  end

  def start_thread(lane)
    return unless SLOTS.try_acquire

    begin
      scope = (@thread_scope ||= Captain::Runtime::Council::ThreadScope.capture)
      lane.each { |plan| publish_part_started(plan, lane: 'reader', inline: false) }
    rescue StandardError
      SLOTS.release
      return
    end
    Thread.new do
      Thread.current.report_on_exception = false
      scope.run { run_lane_collecting(lane) }
    rescue StandardError => e
      { outcomes: [], error: e }
    ensure
      SLOTS.release
    end
  end

  # What a thread returns: plain data only. A stale run is returned, not raised, so the calling thread can finish first.
  def run_lane_collecting(lane)
    outcomes = []
    run_lane(lane) { |plan, entry, result| outcomes << [plan, entry, result] }
    { outcomes: outcomes }
  rescue Captain::Conversation::ControlGenerationStaleError => e
    { outcomes: outcomes, stale: e }
  end

  def join(threads)
    return [] if threads.empty?

    ActiveSupport::Dependencies.interlock.permit_concurrent_loads { threads.map { |lane, thread| [lane, thread.value] } }
  end

  # A lane that turned stale leaves its parts open: the next run does them. A lane that failed for another reason (an internal
  # error of the thread) is a technical failure of its parts that did not finish.
  def settle_threads(outcomes)
    stale = nil
    outcomes.each do |lane, outcome|
      outcome[:outcomes].each { |plan, entry, result| record_outcome(plan, entry, result) }
      if outcome[:stale]
        stale ||= outcome[:stale]
      else
        lane.each do |plan|
          record_outcome(plan, crashed_entry(plan.part, outcome[:error]), nil) unless @entries.key?(plan.part['id'])
        end
      end
    end
    raise stale if stale
  end

  # The parts of one lane, in plan order. The block gets each finished part at once, so that a booking which already happened
  # is never lost when a later part turns stale.
  def run_lane(lane)
    previous = Current.executed_by
    prior = []
    lane.each do |plan|
      break if @aborted.true?

      Current.executed_by = plan.actor
      outcome = run_one(plan, prior)
      prior << outcome[1]
      yield(*outcome)
    end
  ensure
    Current.executed_by = previous
  end

  def run_one(plan, prior)
    return [plan, not_started_entry(plan, prerequisite_failure(plan, prior)), nil] unless prerequisite_ready?(plan, prior)

    publish_part_started(plan, lane: plan.writer ? 'writer' : 'reader', inline: true) if Thread.current == @calling_thread
    plan.snapshot[:part_prior] = prior.map { |entry| entry.slice(:text, :status, :acted) }
    part_run = Captain::Runtime::Council::PartRun.new(
      agent: plan.agent, snapshot: plan.snapshot, account: @account, llm_context: @llm_context, callbacks: @shared_callbacks,
      max_turns: PART_MAX_TURNS
    )
    begin
      result = part_run.call(plan.part['fragment'])
    rescue Captain::Conversation::ControlGenerationStaleError
      @aborted.make_true
      record_interrupted(plan, part_run)
      raise
    rescue StandardError => e
      # An internal error ends this part, not the council: the other parts are still answered.
      Rails.logger.warn("[CAPTAIN][Council] part failed error_class=#{e.class.name}")
      return [plan, crashed_entry(plan.part, e, acted: part_run.tracker.acted?, summary: part_run.tracker.summary), nil]
    end
    [plan, build_entry(plan, result), result]
  end

  # A dependent part (relation depends_on) starts only when the part it depends on ended done or answered: a failed or unknown
  # step stops its chain. A conditional part always starts: its owner decides, from the result of the part before it.
  def prerequisite_ready?(plan, prior)
    part = plan.part
    return true unless part['relation'] == 'depends_on' && part['depends_on_part_id'].present?

    %w[done answered].include?(prior_state(part['depends_on_part_id'], prior))
  end

  def prior_state(part_id, prior)
    entry = prior_entry(part_id, prior)
    return entry[:state] if entry

    Array(@context[:parts]).find { |item| item['id'] == part_id }&.dig('state')
  end

  def prior_entry(part_id, prior)
    prior.find { |item| item[:id] == part_id } || @entries[part_id]
  end

  # The technical failure of the part that a dependent part waits for, when it has one (a dependent of a dependent inherits it).
  def prerequisite_failure(plan, prior)
    part_id = plan.part['depends_on_part_id']
    return if part_id.blank?

    prior_entry(part_id, prior)&.dig(:technical)
  end

  # The write of a part that ran before the run went stale is kept: the provider call already happened.
  def record_interrupted(plan, part_run)
    return unless part_run.tracker.acted?

    registry.record_result!(plan.part['id'], state: 'done', summary: part_run.tracker.summary, acted: true)
  rescue StandardError => e
    Rails.logger.warn("[CAPTAIN][Council] could not store an interrupted part error_class=#{e.class.name}")
  end

  # One more run for a part that said it is not its own and named the responsible agent: once, and only when nothing was done.
  def reassign_pass(plans)
    plans.each do |plan|
      entry = @entries[plan.part['id']]
      next unless entry && entry[:status] == 'out_of_scope' && !entry[:acted] && !entry[:technical]

      suggested = suggested_agent(entry[:suggested_agent])
      reassign(plan, suggested) if suggested && suggested.id != plan.part['executor_agent_id']
    end
  end

  def reassign(plan, suggested)
    new_plan = build_plan(plan.part.merge('executor_agent_id' => suggested.id))
    return unless new_plan.runnable?

    # The new owner is stored first: the receipt of an action checks that the part belongs to the agent that acts.
    registry.record_result!(plan.part['id'], state: 'open', executor_agent_id: suggested.id)
    @participants = (@participants + [suggested.id]).uniq
    run_lane([new_plan]) { |next_plan, entry, result| record_outcome(next_plan, entry, result) }
  end

  # The part names the agent as it is listed in its prompt and never sees an id; an unknown or ambiguous name reassigns nothing.
  def suggested_agent(name)
    wanted = Captain::Runtime::ExecutorResolver.normalize(name)
    return if wanted.empty?

    matches = @graph.agents.select { |agent| Captain::Runtime::ExecutorResolver.normalize(agent.name) == wanted }
    matches.first if matches.one?
  end

  # --- The outcome of a part ------------------------------------------------------------------------------------------------

  # The entry is what the reply and the registry need of a part. It is built from plain data only, so it can be built on a thread.
  def build_entry(plan, result)
    base = entry_base(plan.part).merge(acted: result[:acted], pending: result[:pending], summary: result[:summary].to_s)
    return technical_entry(base, result[:technical]) if result[:technical]

    output = result[:output]
    outcome = output ? answer_outcome(output, base) : unparsed_outcome(base)
    base.merge(outcome).merge(unresolved: UNRESOLVED_STATES.include?(outcome[:state]),
                              stored: stored_summary(output&.dig('customer_text'), outcome[:text], base))
  end

  # What the registry keeps of the part for later runs: the text its owner wrote; else, for a part that acted, what its tools
  # returned; else the text that was sent.
  def stored_summary(written, sent, base)
    written.to_s.presence || (base[:acted] ? base[:summary].presence : sent.presence)
  end

  def entry_base(part)
    {
      id: part['id'], executor_id: part['executor_agent_id'], request: part['fragment'].to_s.strip.first(160),
      patient: part['patient'].to_s.strip.downcase, questions: [], unresolved: false, acted: false, summary: ''
    }
  end

  # The registry state and the text of a part, from what the owner said and what its tools did. That an action was performed is
  # computed from the tool results, never from what the owner says. The text is only ever the owner's: it may be blank.
  def answer_outcome(output, base)
    text = output['customer_text'].to_s
    state, text = case output['status']
                  when 'answered' then answered_state(output, text, base)
                  when 'needs_information' then information_state(output, text, base)
                  when 'out_of_scope' then [base[:acted] ? 'unknown' : 'open', text]
                  else ['unknown', text]
                  end
    { status: output['status'], state: state, text: text, questions: output['questions'], sources: output['sources'],
      suggested_agent: output['suggested_agent'] }
  end

  # An action that was performed is done. An answer without a source (a tool, a document, the agent's own instructions) is not
  # an answer: its text is not passed on.
  def answered_state(output, text, base)
    return ['done', text] if base[:acted]
    return ['answered', text] if text.present? && output['sources'].any?

    ['unknown', '']
  end

  # The owner asks the customer for everything still missing in one message; its listed questions stand in for a missing text.
  def information_state(output, text, base)
    text = text.presence || output['questions'].join(' ')
    return ['waiting_customer', text] if text.present?

    [base[:acted] ? 'done' : 'unknown', '']
  end

  # No usable structured answer. An action that was performed is still done, and it has no text.
  def unparsed_outcome(base)
    return { status: 'answered', state: 'done', text: '' } if base[:acted]

    { status: 'unavailable', state: 'unknown', text: '' }
  end

  # A technical failure: the part is not mentioned, also when it had already performed an action (staff are told, see
  # #staff_note, and the failure hands the conversation over).
  def technical_entry(base, technical)
    return base.merge(status: 'answered', state: 'done', text: '', technical: technical, stored: base[:summary].presence) if base[:acted]

    base.merge(status: 'unavailable', state: 'unknown', text: '', technical: technical)
  end

  # An internal error of a part (not of one of its tools). It is a technical failure like any other; what its tools did before
  # the error is kept.
  def crashed_entry(part, error, acted: false, summary: '')
    technical = { 'kind' => Captain::Runtime::ToolFailure::TECHNICAL, 'reason' => 'council_error', 'error_class' => error&.class&.name }.compact
    technical_entry(entry_base(part).merge(acted: acted, summary: summary.to_s), technical)
  end

  # A dependent part whose prerequisite has not finished does not run, and the customer is not told about it: the text of the
  # prerequisite (its question) carries the reply, and the part stays open for the next message. When the prerequisite failed
  # technically, that failure is the dependent's too, so the note for staff names it and the handoff follows the reply.
  def not_started_entry(plan, failure = nil)
    entry = entry_base(plan.part).merge(state: 'open', text: '', status: 'unavailable', not_started: true)
    failure ? entry.merge(technical: failure) : entry
  end

  # A part of an earlier attempt of the request, or a part whose owner is no longer there. It is replayed with the text that was
  # sent for it, and with its technical failure, so that a retried job tells and does the same as the first attempt.
  def immediate_entry(plan)
    stored = plan.settled
    return unavailable_entry(plan.part) unless stored

    entry = entry_base(plan.part).merge(state: stored['state'], text: settled_text(stored), acted: stored['acted'] == true,
                                        questions: Array(stored['missing_fields']),
                                        unresolved: UNRESOLVED_STATES.include?(stored['state']), settled: true)
    stored['technical'].blank? ? entry : entry.merge(technical: stored['technical'])
  end

  # What the customer was told for a stored part: the text that was sent, and nothing else. A part stored without one (a cancelled
  # part, an older record, a part whose run was interrupted after it acted) has no text and is left out of the reply; the summary
  # holds the raw results of its tools for the model and for staff, and is never sent.
  def settled_text(stored)
    stored['reply_text'].to_s
  end

  def unavailable_entry(part)
    entry_base(part).merge(state: 'unknown', text: '', status: 'unavailable', unresolved: true)
  end

  # --- Recording (calling thread only) --------------------------------------------------------------------------------------

  def record_outcome(plan, entry, result)
    @entries[plan.part['id']] = entry
    @results << result if result.is_a?(Hash) && result.key?(:tracking)
    return if entry[:settled]

    unless entry[:not_started]
      # reply_text is what the customer is told for this part, kept apart from the summary (which holds what the tools returned,
      # for the model and for staff), so that a retried job replays the sentence and never a tool dump.
      registry.record_result!(plan.part['id'], state: entry[:state], summary: entry[:stored], missing_fields: entry[:questions],
                                               executor_agent_id: plan.part['executor_agent_id'], acted: entry[:acted],
                                               reply_text: entry[:text].to_s, technical: entry[:technical])
    end
    publish_part_finished(plan, entry, result)
  end

  def registry
    Captain::Runtime::PartRegistry.new(@context)
  end

  # What the parts called is what the main run did: the retry and fallback logic of the runner reads it, and a completed action
  # makes a blank-response retry unsafe. The appointment evidence is already left out (see PartRun).
  def merge_tool_tracking
    @monitor.synchronize do
      @results.each do |result|
        tracking = result[:tracking].to_h
        (@context[:captain_v2_completed_tool_names] ||= []).concat(Array(tracking[:completed_tool_names]))
        (@context[Captain::Runtime::ToolWrapper::COMPLETED_ACTIONS_KEY] ||= []).concat(Array(tracking[:completed_actions]))
        merged = (@context[:captain_v2_completed_tool_results] ||= []).concat(Array(tracking[:completed_tool_results]))
        @context[:captain_v2_completed_tool_results] = merged.last(MAX_COMPLETED_TOOL_RESULT_RECORDS)
        @context[:captain_v2_artifact_ids] = Array(@context[:captain_v2_artifact_ids]) | Array(tracking[:artifact_ids])
      end
      @results = []
    end
  end

  def publish_part_started(plan, lane:, inline:)
    Captain::Runtime::CoordinationEvents.part_started(context: @context, part: plan.part, lane: lane, inline: inline)
  end

  def publish_part_finished(plan, entry, result)
    result = result.is_a?(Hash) ? result : {}
    details = { state: entry[:state], status: entry[:status], acted: entry[:acted] == true,
                mutations_succeeded: result[:mutations_succeeded].to_i, mutations_failed: result[:mutations_failed].to_i,
                mutations_unknown: result[:mutations_unknown].to_i, tools_called: result[:tools_called].to_i,
                turns: result[:turns].to_i, duration_ms: result[:duration_ms].to_i }
    Captain::Runtime::CoordinationEvents.part_finished(context: @context, part: plan.part, **details)
    Rails.logger.info("[CAPTAIN][Council] part_finished part_id=#{plan.part['id']} version=#{plan.part['version']} " \
                      "executor_agent_id=#{plan.part['executor_agent_id']} #{details.map { |key, value| "#{key}=#{value}" }.join(' ')}")
  end

  # --- The reply ------------------------------------------------------------------------------------------------------------

  # The reply holds the texts the owners wrote, and nothing else. A part without a text (one that failed technically, one that
  # could not be resolved, a dependent part that did not start, a cancelled part, a part that acted and wrote nothing) is left
  # out; parts that failed technically or could not be resolved hand the conversation to staff after the reply, in silence. When
  # no part has a text the reply is empty: with a technical failure the run ends as a failed turn (see Runner#handle_plan),
  # otherwise nothing is sent, and the conversation still goes to staff when a part is unresolved.
  def assemble(entries)
    @context.delete(:council_handoff)
    @context.delete(:council_note)
    failures = entries.filter_map { |entry| entry[:technical] }
    shown = entries.select { |entry| told?(entry) }
    return no_reply(failures) if shown.empty? && failures.any?

    unresolved = entries.select { |entry| entry[:unresolved] && !entry[:technical] }
    handoff = failures.any? || (unresolved.any? && staff_handoff_available?)
    reply = reply_for(shown, handoff: handoff)
    @context[:council_untold_part_ids] = entries.reject { |entry| told?(entry) }.pluck(:id)
    @context[:council_handoff] = handoff_request(unresolved, failures) if handoff
    mark_handed_to_staff(entries) if handoff
    staff_note(entries, unresolved, handoff: handoff)
    reply
  end

  # The parts the conversation goes to staff for (the unresolved ones and the ones that failed technically) are theirs now: the
  # coordination prompt no longer lists them as open parts of a colleague (they stay linkable by number).
  def mark_handed_to_staff(entries)
    entries.select { |entry| entry[:unresolved] || entry[:technical] }.each do |entry|
      registry.record_result!(entry[:id], handed_to_staff: true)
    rescue StandardError => e
      Rails.logger.warn("[CAPTAIN][Council] could not mark a part handed to staff error_class=#{e.class.name}")
    end
  end

  def reply_for(shown, handoff:)
    return '' if shown.empty?

    lines = shown.map { |entry| part_line(entry, handoff: handoff) }
    lines.one? ? lines.first['text'] : (edit_reply(shown.pluck(:id), lines, handoff: handoff) || plain_reply(shown, lines))
  end

  # The customer reads the text of a part only when its owner wrote one.
  def told?(entry)
    entry[:text].present?
  end

  def no_reply(failures)
    @context[:technical_failure] = failures.first.merge('parts' => failures.size)
    ''
  end

  # A private note for staff, never customer text: what a part did without any text that tells the customer (the action is on
  # record, and the next reply mentions it, see PartRegistry.undelivered_outcomes), and what nobody will answer because the
  # conversation cannot go to staff. The response builder writes it (see ResponseBuilderJob#note_council_parts).
  def staff_note(entries, unresolved, handoff:)
    unreported = entries.select { |entry| entry[:acted] && !told?(entry) }.pluck(:request)
    unanswered = handoff ? [] : unresolved.reject { |entry| told?(entry) }.pluck(:request)
    note = { unreported: unreported.compact_blank, unanswered: unanswered.compact_blank }.compact_blank
    @context[:council_note] = note if note.any?
  end

  def handoff_request(unresolved, failures)
    request = { reason: failures.any? ? TECHNICAL_HANDOFF_REASON : HANDOFF_REASON, parts: unresolved.pluck(:request) }
    request.merge!(technical: true, failures: failures) if failures.any?
    request
  end

  # The agents that wrote a part of the reply. An agent none of whose parts has a text is not one of them.
  def contributors
    shown = @entries.values.select { |entry| told?(entry) }.pluck(:executor_id)
    hidden = @entries.values.reject { |entry| told?(entry) }.pluck(:executor_id) - shown
    (@participants - hidden).filter_map do |id|
      actor = @graph&.find(id)
      { id: actor.id, name: actor.name, avatar_url: actor.avatar_url } if actor
    end
  end

  # What the editor gets of a part: the text its owner wrote and two flags. The owner of a part was told whether staff can take
  # it over, so its own sentence is true; staff_will_answer says the same to the editor.
  def part_line(entry, handoff:)
    { 'text' => entry[:text], 'done' => entry[:acted] == true, 'staff_will_answer' => entry[:unresolved] == true && handoff }
  end

  # Without the editor's reply the part texts go out in the order of the requests. Exact repeats are dropped (the same question
  # twice for one person); the same words about different people stay, since they ask about different people.
  def plain_reply(entries, lines)
    keyed = entries.zip(lines).map { |entry, line| [[entry[:patient], line['text']], line['text']] }
    keyed.uniq(&:first).filter_map { |_, text| text.presence }.join(PART_SEPARATOR)
  end

  def edit_reply(ids, lines, handoff:)
    outcome = Captain::Runtime::CouncilEditor.new(
      context: @context, account: @account, llm_context: @llm_context, model: editor_model
    ).edit(message: customer_message, language: reply_language, parts: lines)
    if outcome.reply.blank?
      Captain::Runtime::CoordinationEvents.council_editor_fallback(context: @context, part_ids: ids, reason: outcome.reason)
      return
    end

    Captain::Runtime::CoordinationEvents.council_edited(context: @context, part_ids: ids, language: reply_language, handoff: handoff)
    outcome.reply
  rescue Captain::Conversation::ControlGenerationStaleError
    raise
  rescue StandardError => e
    Rails.logger.warn("[CAPTAIN][Council] editor unavailable error_class=#{e.class.name}")
    Captain::Runtime::CoordinationEvents.council_editor_fallback(context: @context, part_ids: ids, reason: 'error')
    nil
  end

  def customer_message
    @customer_message ||= Captain::Runtime::CouncilEditor.customer_text(@context[:captain_v2_current_input]).strip
  end

  def reply_language
    @reply_language ||= Captain::Runtime::CouncilEditor.language_for(customer_message, history: @context[:conversation_history])
  end

  def acting_actor
    @graph&.find(@context[:acting_assistant_id] || @context.dig(:state, :assistant_id)) || @graph&.entry
  end

  def editor_model
    @model.presence || acting_actor&.resolved_agent_model
  end

  # The same conditions the response builder checks before it hands the conversation to staff.
  def staff_handoff_available?
    return @staff_handoff_available if defined?(@staff_handoff_available)

    @staff_handoff_available = begin
      actor = acting_actor
      (@context.dig(:state, :conversation, :id).present? && actor.present? && actor.handoff_enabled? &&
        Array(actor.selected_agent_tool_ids).include?('handoff')).present?
    rescue StandardError
      false
    end
  end

  # One callback at a time, whichever thread calls it: the callbacks of the run (the event bus, the tool trace, the typing
  # indicator) were written for a single thread and share records and counters.
  def serialized(callbacks)
    callbacks.to_h.to_h do |event_type, list|
      wrapped = Array(list).map do |callback|
        lambda do |*args|
          @monitor.synchronize { Captain::Runtime::CallbackManager.new(event_type => [callback]).emit(event_type, *args) }
        end
      end
      [event_type, wrapped]
    end
  end
end
