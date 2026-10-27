require 'monitor'
require 'timeout'

module Enterprise::Captain::ReplySuggestionService
  module AgentCatalogHelpers
    private

    # The anchor answers a channel of one agent; with two or more agents nobody is active until the router chose (the anchor is
    # not "thinking" while the router decides).
    def init_agent_catalog!(assistant)
      @assistant = assistant
      @agents_by_id = {}
      @agents_by_name = {}
      @working_agents = []
      @routed = index_agents! > 1
      @active_agent = summary_for(@assistant) unless @routed
    end

    def activate_agent!(actor, role: nil)
      @active_agent = actor if actor.present?
      record_working_agent(actor, role: role)
    end

    def record_working_agent(agent_summary, role: nil)
      name = agent_summary.is_a?(Hash) ? agent_summary['name'] : nil
      return if name.blank?

      existing = find_working_agent(agent_summary)
      return upgrade_role(existing, role) if existing

      entry = agent_summary.dup
      entry['role'] = role if role.present?
      @working_agents << entry
      entry
    end

    def agent_by_id(id)
      @agents_by_id[id.to_i] if id.present?
    end

    def agent_by_name(name)
      key = normalize_name(name)
      return if key.blank?

      @agents_by_name[key] || { 'name' => name.to_s.strip }
    end

    def actor_from_context(context_wrapper, fallback_name = nil)
      ctx = context_wrapper&.context
      actor = actor_from_hash(ctx) if ctx.is_a?(Hash)
      actor || agent_by_name(fallback_name) || @active_agent
    end

    def resolve_responder(payload)
      agent_by_id(payload[:agent_id]) ||
        agent_by_name(payload[:agent_display_name].presence || payload[:agent_name].presence) ||
        @active_agent
    end

    # Returns how many candidates the router chooses among (0 or 1: there is no decision).
    def index_agents!
      graph = agent_graph
      graph_actors(graph).each { |actor| register_actor(actor) }
      candidate_count(graph)
    end

    def agent_graph
      Captain::AgentGraph.new(@assistant, inbox: @conversation&.inbox) if @assistant.persisted?
    rescue StandardError
      nil
    end

    def graph_actors(graph)
      actors = graph ? graph.agents : [@assistant]
      (Array(actors) + [@assistant]).compact.uniq(&:id)
    rescue StandardError
      [@assistant].compact
    end

    def candidate_count(graph)
      graph ? graph.candidates.size : 0
    rescue StandardError
      0
    end

    def register_actor(actor)
      summary = summary_for(actor)
      return if summary.blank?

      @agents_by_id[actor.id.to_i] = summary if actor.id.present?
      @agents_by_name[normalize_name(actor.name)] = summary if actor.name.present?
      return unless actor.respond_to?(:agent_name) && actor.agent_name.present?

      @agents_by_name[normalize_name(actor.agent_name)] = summary
    end

    def summary_for(actor)
      return if actor.blank?

      name = actor.name.to_s.strip.presence || (actor.respond_to?(:agent_name) ? actor.agent_name.to_s : '')
      avatar = actor.respond_to?(:avatar_url) ? actor.avatar_url.to_s.presence : nil
      { 'id' => actor.id, 'name' => name, 'avatar_url' => avatar }.compact
    end

    def actor_from_hash(ctx)
      assistant_id = ctx[:part_run] ? ctx.dig(:state, :assistant_id) : (ctx[:acting_assistant_id] || ctx.dig(:state, :assistant_id))
      agent_by_id(assistant_id) || agent_by_name(ctx[:current_agent])
    end

    def find_working_agent(summary)
      target_id = summary['id']
      target_name = normalize_name(summary['name'])
      @working_agents.find do |entry|
        (target_id.present? && entry['id'] == target_id) || normalize_name(entry['name']) == target_name
      end
    end

    def upgrade_role(entry, role)
      entry['role'] = role if role.present? && entry['role'].blank?
      entry
    end

    def normalize_name(value)
      value.to_s.strip.downcase
    end
  end

  module CouncilTrackerHelpers
    private

    def upsert_council_part!(context, actor, status:)
      part_id = context[:active_part_id].to_s
      return if part_id.blank?

      info = context[:part_info].to_h
      entry = (@council_parts[part_id] ||= { 'id' => info[:id] || part_id })
      merge_part_fields!(entry, info, actor, status)
    end

    def capture_council_completion!(raw_content, context, actor)
      parsed = Captain::Runtime::Council::PartRun.parse_output(raw_content)
      return if parsed.blank?

      upsert_council_part!(context, actor, status: parsed['status'].presence || 'answered')
      part_entry = @council_parts[context[:active_part_id].to_s]
      return unless part_entry

      part_entry['reasoning'] = sanitize_text(parsed['reasoning']) if parsed['reasoning'].present?
      part_entry['customer_text'] = sanitize_text(parsed['customer_text']) if parsed['customer_text'].present?
      part_entry.compact!
    end

    def combined_council_reasoning
      lines = @council_parts.values.filter_map do |part|
        next if part['reasoning'].blank?

        agent_label = part.dig('agent', 'name').presence
        agent_label ? "#{agent_label}: #{part['reasoning']}" : part['reasoning']
      end
      lines.join("\n\n").presence
    end

    def resolve_council_contributors(payload)
      explicit = explicit_contributors(payload)
      return explicit if explicit.present?
      return [] if @council_parts.empty?

      @council_parts.values.filter_map { |part| part['agent'] }.uniq { |agent| agent['id'] || agent['name'] }
    end

    # payload: the answer of the run; a council answer carries the status every part ended with (council_parts), which replaces the
    # status shown while it ran, so a part that stopped without a result of its own is never shown as still running.
    def council_snapshot(payload = nil)
      return if @council_parts.empty?

      settle_council_parts!(payload)
      { 'active' => true, 'parts' => @council_parts.values.map(&:dup) }
    end

    def settle_council_parts!(payload)
      Array(payload.to_h.with_indifferent_access[:council_parts]).each do |final|
        final = final.to_h.with_indifferent_access
        entry = @council_parts[final[:id].to_s]
        next if entry.blank? || final[:status].blank?

        entry['status'] = final[:status].to_s
        entry['stop_reason'] = final[:stop_reason].to_s if final[:stop_reason].present?
      end
    end

    def sanitize_text(value)
      text = value.to_s.strip
      return if text.blank?

      sanitized = Captain::ToolTraceBuilder.sanitize_payload(text)
      sanitized.is_a?(Hash) ? sanitized['preview'].to_s : sanitized.to_s
    end

    def merge_part_fields!(entry, info, actor, status)
      entry['fragment'] ||= sanitize_text(info[:fragment])
      entry['patient'] ||= sanitize_text(info[:patient])
      entry['relation'] ||= info[:relation].to_s.presence
      entry['agent'] ||= actor
      entry['status'] = status
      entry.compact!
    end

    def explicit_contributors(payload)
      Array(payload[:council_contributors]).filter_map do |entry|
        hash = entry.to_h.with_indifferent_access
        next if hash[:name].blank?

        { 'id' => hash[:id], 'name' => hash[:name].to_s, 'avatar_url' => hash[:avatar_url].presence }.compact
      end
    end
  end

  class TraceCollector
    include AgentCatalogHelpers
    include CouncilTrackerHelpers

    # progress_context: { suggestion_request_id:, conversation_id: (the id the client sent), started_at:, deadline_at:, budget_seconds: }
    def initialize(assistant:, conversation:, user:, progress_context: nil)
      @conversation = conversation
      @user = user
      @progress_context = progress_context
      @broadcaster = Captain::ReplySuggestion::Broadcaster.new(user: user)
      @turns = 0
      @tools_called = 0
      @preload = nil
      @monitor = Monitor.new
      @council_parts = {}
      @tool_trace_steps = []
      @sequence = 0
      @handoffs = []
      @routing = nil
      @pending_actions = []
      @superseded_action_ids = []
      @reasoning = nil
      init_agent_catalog!(assistant)
      # While the router decides who answers, the manager sees that, and no agent.
      @phase = @routed ? 'routing' : 'thinking'
    end

    def callbacks
      {
        on_agent_thinking: method(:handle_agent_thinking),
        on_tool_start: method(:handle_tool_start),
        on_tool_progress: method(:handle_tool_progress),
        on_tool_complete: method(:handle_tool_complete),
        on_agent_routed: method(:handle_agent_routed),
        on_llm_call_complete: method(:handle_llm_call_complete),
        on_suggestion_preload: method(:handle_suggestion_preload)
      }
    end

    def broadcast_initial!
      @monitor.synchronize { broadcast_progress! }
    end

    # Counters for the outcome event.
    def stats
      @monitor.synchronize do
        { tools_called: @tools_called, turns: @turns, handoffs_count: @handoffs.size, preloaded: @preload&.fetch('parts', nil).presence,
          preload_ms: @preload&.fetch('ms', nil) }.compact
      end
    end

    def captain_trace(payload)
      @monitor.synchronize do
        Captain::ToolTraceBuilder.payload(@tool_trace_steps, **reasoning_attributes(payload))
      end
    end

    def suggestion_meta(payload)
      @monitor.synchronize do
        responder = resolve_responder(payload)
        record_working_agent(responder, role: 'responder') if responder.present?

        {
          'agent' => responder,
          'working_agents' => @working_agents.presence,
          'council_contributors' => resolve_council_contributors(payload).presence,
          'council' => council_snapshot(payload),
          'handoffs' => @handoffs.presence,
          'routing' => @routing,
          'pending_actions' => resolve_pending_actions(payload).presence,
          'superseded_action_ids' => @superseded_action_ids.presence
        }.compact
      end
    end

    private

    def handle_agent_thinking(agent_name, _input = nil, context_wrapper = nil)
      @monitor.synchronize do
        actor = actor_from_context(context_wrapper, agent_name)
        if part_run?(context_wrapper)
          @phase = 'council_running'
          record_working_agent(actor, role: 'council')
          upsert_council_part!(context_wrapper.context, actor, status: 'running')
        else
          @phase = 'thinking'
          @turns += 1
          activate_agent!(actor)
        end
        broadcast_progress!
      end
    end

    # What the run read at its start instead of with tools: { 'parts' => ['card', 'appointments', ...], 'ms' => n } (see
    # Captain::ReplySuggestion::PatientPreload). It is counted in the outcome event.
    def handle_suggestion_preload(preload)
      @monitor.synchronize { @preload = preload.to_h.stringify_keys }
    end

    def handle_tool_start(tool_name, args = nil, context_wrapper = nil)
      @monitor.synchronize do
        actor = actor_from_context(context_wrapper)
        in_council = part_run?(context_wrapper)
        record_working_agent(actor, role: in_council ? 'council' : nil)
        @phase = in_council ? 'council_running' : 'tool_running'
        @tools_called += 1
        append_step!(tool_name: tool_name, event: 'start', input: args, current_agent: actor&.dig('name'))
        broadcast_progress!
      end
    end

    def handle_tool_progress(tool_name, details = nil, context_wrapper = nil)
      @monitor.synchronize do
        actor = actor_from_context(context_wrapper)
        append_step!(tool_name: tool_name, event: 'progress', output: details, current_agent: actor&.dig('name'))
        broadcast_progress!
      end
    end

    def handle_tool_complete(tool_name, result = nil, context_wrapper = nil)
      @monitor.synchronize do
        actor = actor_from_context(context_wrapper)
        normalized = Captain::ToolResult.normalize(result)
        event = Captain::ToolResult.error?(normalized) ? 'failed' : 'finish'
        append_step!(tool_name: tool_name, event: event, output: normalized, current_agent: actor&.dig('name'))
        capture_pending_actions!(context_wrapper&.context)
        broadcast_progress!
      end
    end

    # The cards of the run so far. A card that a corrected card of the same action replaced (another time for the same appointment)
    # was rejected and leaves the list: the operator approves only the card the draft names. Its id goes with the progress and the
    # result (superseded_action_ids), so that the manager's panel, which keeps the cards it was shown, drops it too.
    def capture_pending_actions!(context)
      @superseded_action_ids = (@superseded_action_ids + superseded_action_ids_of(context)).uniq
      actions = Array(context&.dig(Captain::ReplySuggestion::ActionApprovalService::CONTEXT_KEY))
      @pending_actions = without_superseded((@pending_actions + actions).uniq { |item| item['action_id'] || item[:action_id] })
    end

    def superseded_action_ids_of(context)
      Array(context&.dig(Captain::ReplySuggestion::ActionApprovalService::SUPERSEDED_CONTEXT_KEY)).map(&:to_s)
    end

    def without_superseded(actions)
      return actions if @superseded_action_ids.blank?

      actions.reject { |item| @superseded_action_ids.include?(item.to_h.stringify_keys['action_id'].to_s) }
    end

    # The cards of this run: what the run reported, and what it stored (a card of a part on a thread); after them the cards of an
    # earlier suggestion that the manager inserted or sent and that still wait for approval (kept, see ActionApprovalService). Other
    # cards of earlier suggestions are not this suggestion's (a new suggestion discards them, see StartService).
    def resolve_pending_actions(payload)
      combined = Array(payload[:pending_actions]) + @pending_actions + stored_pending_actions
      items = combined.filter_map do |entry|
        hash = entry.to_h.deep_stringify_keys
        hash if hash['action_id'].present?
      end
      without_superseded(items).uniq { |item| item['digest'].presence || item['action_id'] }
    end

    def stored_pending_actions
      request_id = @progress_context.to_h[:suggestion_request_id]
      return [] if request_id.blank?

      Array(Captain::ReplySuggestion::ActionApprovalService.pending_for(
              account_id: @conversation&.account_id, conversation_id: @conversation&.id, request_id: request_id
            ))
    end

    # The router's decision for the turn (keys, ids and models only): who drafts the suggestion, or a council of exactly these agents.
    def handle_agent_routed(decision, _context_wrapper = nil)
      @monitor.synchronize do
        decision = decision.to_h.with_indifferent_access
        @routing = decision.slice(:decision_key, :kind, :decided_by, :confidence)
                           .to_h.compact.presence
        # A message that needs no answer runs no agent (see AgentRunnerService#routed_no_reply_suggestion): none is shown at work.
        targets = decision[:kind].to_s == 'no_reply' ? [] : Array(decision[:target_ids]).filter_map { |id| agent_by_id(id) }
        if decision[:kind].to_s == 'council'
          targets.each { |actor| record_working_agent(actor, role: 'council') }
          @phase = 'council_running'
        elsif targets.any?
          route_to!(targets.first, decision)
        end
        broadcast_progress!
      end
    end

    def route_to!(target, decision)
      from_actor = agent_by_id(decision[:from_agent_id])
      activate_agent!(target, role: 'routed')
      @phase = 'thinking'
      return if from_actor.blank? || from_actor['id'] == target['id']

      @phase = 'handoff'
      @handoffs << build_handoff_entry(from_actor, target, nil, nil, decision[:decision_key])
    end

    def handle_llm_call_complete(agent_name, _model = nil, response = nil, context_wrapper = nil)
      raw_content = extract_llm_content(response)
      return if raw_content.blank?

      @monitor.synchronize do
        if part_run?(context_wrapper)
          actor = actor_from_context(context_wrapper, agent_name)
          capture_council_completion!(raw_content, context_wrapper.context, actor)
        else
          capture_main_reasoning!(raw_content)
        end
        broadcast_progress!
      end
    end

    def part_run?(context_wrapper)
      context_wrapper&.context&.dig(:part_run).present?
    rescue StandardError
      false
    end

    def extract_llm_content(response)
      return if response.nil? || (response.respond_to?(:tool_call?) && response.tool_call?)

      response.respond_to?(:content) ? response.content : nil
    end

    def build_handoff_entry(from_actor, to_actor, from_name, to_name, reason)
      {
        'from' => from_actor&.dig('name') || from_name.to_s,
        'to' => to_actor&.dig('name') || to_name.to_s,
        'reason' => reason.to_s.presence
      }.compact
    end

    def append_step!(tool_name:, event:, input: nil, output: nil, current_agent: nil)
      @sequence += 1
      @tool_trace_steps << Captain::ToolTraceBuilder.step(
        tool_name: tool_name, event: event, sequence: @sequence,
        input: input, output: output, current_agent: current_agent
      )
    end

    def capture_main_reasoning!(raw_content)
      parsed = raw_content.is_a?(Hash) ? raw_content : JSON.parse(raw_content.to_s)
      return unless parsed.is_a?(Hash)

      extracted = parsed['reasoning'] || parsed[:reasoning]
      @reasoning = sanitize_text(extracted) if extracted.present?
    rescue JSON::ParserError
      nil
    end

    def reasoning_attributes(payload)
      separated = {
        native_reasoning: payload[:native_reasoning],
        structured_reasoning: payload[:structured_reasoning],
        system_fallback_reason: payload[:system_fallback_reason]
      }.compact_blank
      return separated if separated.present?

      { reasoning: payload[:reasoning].presence || @reasoning.presence || combined_council_reasoning }.compact_blank
    end

    def broadcast_progress!
      data = progress_payload
      @broadcaster.progress(data)
      snapshot_progress(data)
    rescue StandardError => e
      Rails.logger.debug { "[CAPTAIN][ReplySuggestionService] Progress broadcast skipped: #{e.message}" }
    end

    # The last progress is kept in Redis for a manager who returns to the conversation (at most once a second, and on each change
    # of phase). It runs on the thread of the job, which is the only writer of the request.
    def snapshot_progress(data)
      request_id = @progress_context.to_h[:suggestion_request_id]
      return if request_id.blank?

      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return if @snapshot_phase == @phase && @snapshot_at && now - @snapshot_at < Captain::ReplySuggestion::PROGRESS_WRITE_INTERVAL

      @snapshot_at = now
      @snapshot_phase = @phase
      Captain::ReplySuggestion::RequestStore.write_progress(request_id, data)
    end

    def progress_payload
      request_progress_fields.merge(
        phase: @phase,
        active_agent: @active_agent,
        working_agents: @working_agents,
        handoffs: @handoffs.presence,
        council: council_snapshot,
        pending_actions: @pending_actions.presence,
        superseded_action_ids: @superseded_action_ids.presence,
        captain_trace: Captain::ToolTraceBuilder.payload(
          @tool_trace_steps,
          reasoning: @reasoning.presence || combined_council_reasoning
        )
      ).compact
    end

    # Which request the progress belongs to, and its timing. conversation_id is the id the client sent (it differs from the
    # conversation's own display id for a communication thread).
    def request_progress_fields
      context = @progress_context.to_h
      fields = {
        account_id: @conversation&.account_id,
        conversation_id: context[:conversation_id] || @conversation&.display_id,
        conversation_record_id: @conversation&.id
      }
      context[:suggestion_request_id].blank? ? fields : fields.merge(request_timing_fields(context))
    end

    def request_timing_fields(context)
      started_at = context[:started_at]
      {
        suggestion_request_id: context[:suggestion_request_id], status: 'running', budget_seconds: context[:budget_seconds],
        started_at: started_at&.utc&.iso8601(3), deadline_at: context[:deadline_at]&.utc&.iso8601(3),
        elapsed_ms: (((Time.current - started_at) * 1000).round if started_at)
      }
    end
  end

  # The engine of the request, chosen when it starts (StartService) and never changed by the run: a request for the agent does not
  # fall back to the old prompt. The assistant found here (the assistant of the inbox, else the account default, else the first one
  # that can take the conversation) is the technical anchor of the run only: the router decides which agent drafts the suggestion.
  def suggestion_engine
    assistant = anchor_assistant_for_suggestion
    assistant ? { engine: 'agent', assistant_id: assistant.id } : super
  end

  def start_error_code
    code = super
    return code if code == :disabled
    return :quota_exceeded unless responses_available?

    code
  end

  def run_stats
    @trace_collector&.stats || {}
  end

  private

  def perform_reply_suggestion
    chosen = @engine.present? ? { engine: @engine, assistant_id: @assistant_id } : suggestion_engine
    return super unless chosen[:engine] == 'agent'

    assistant = account.captain_assistants.entry_eligible.find_by(id: chosen[:assistant_id])
    return Captain::ReplySuggestion::Outcome.failed('agent_unavailable') unless assistant

    perform_agent_reply_suggestion(assistant)
  end

  def anchor_assistant_for_suggestion
    return if conversation.blank? || conversation.inbox&.channel_type == 'Channel::Voice'

    inbox_assistant = conversation.inbox&.captain_assistant
    return inbox_assistant if inbox_assistant&.entry_eligible?

    default_account_assistant
  end

  def default_account_assistant
    default_id = account.captain_default_assistant_id
    default_assistant = account.captain_assistants.entry_eligible.find_by(id: default_id) if default_id.present?
    default_assistant || account.captain_assistants.entry_eligible.order(:id).first
  end

  # Whatever happens, the answer is an outcome of the agent: a draft, no reply, a human, or a failure. A run that is cancelled or out
  # of time raises (RunAborted, Timeout::Error) and the job turns that into its outcome.
  def perform_agent_reply_suggestion(assistant)
    return Captain::ReplySuggestion::Outcome.failed('api_key_missing') unless api_key_configured?

    history = Captain::ReplySuggestion::HistoryBuilder.new(account: account, conversation: conversation, assistant: assistant).perform
    Captain::ReplySuggestion::RunControl.checkpoint!(:history)
    @trace_collector = TraceCollector.new(assistant: assistant, conversation: conversation, user: user, progress_context: @progress_context)
    @trace_collector.broadcast_initial!

    classify_agent_response(run_suggestion_agent(assistant, history), history)
  rescue Captain::Conversation::ControlGenerationStaleError, Timeout::Error
    raise
  rescue StandardError => e
    Rails.logger.warn("[CAPTAIN][ReplySuggestionService] Agent suggestion failed: #{e.class}: #{e.message}")
    Captain::ReplySuggestion::Outcome.failed('internal_error', error_class: e.class.name, detail: e.message.to_s.truncate(200))
  end

  def run_suggestion_agent(assistant, history)
    Llm::EventBus.with_context(user_id: user&.id) do
      Captain::Assistant::AgentRunnerService.new(
        assistant: assistant, conversation: conversation, source: 'reply_suggestion', callbacks: @trace_collector.callbacks,
        request_id: @request_id
      ).generate_response(message_history: history)
    end
  end

  def classify_agent_response(raw_response, history = [])
    outcome = Captain::ReplySuggestion::AgentOutcomeClassifier.new(
      raw_response, trace_collector: @trace_collector, patient_text: unanswered_patient_text(history)
    ).perform
    return outcome unless outcome[:outcome] == 'draft' && build_follow_up_context?

    outcome.merge(follow_up_context: build_follow_up_context([{ role: 'user', content: formatted_conversation }], outcome))
  end

  # The patient's messages after the last clinic message: the turn that the suggestion answers (the same as the router's latest
  # message). Read in the classifier for the words of a request, never stored or logged.
  def unanswered_patient_text(history)
    unanswered = Captain::Runtime::RoutingSnapshot.split_history(history).last
    unanswered.filter_map { |message| Captain::Runtime::RoutingSnapshot.text_of(message[:content]).presence }.join("\n")
  end
end
