require 'monitor'
require 'timeout'

module Enterprise::Captain::ReplySuggestionService
  FALLBACK_USER_PROMPT = 'Suggest the next reply for the customer based on the conversation and context.'.freeze
  PROGRESS_EVENT = 'captain.reply_suggestion.progress'.freeze
  SUGGESTION_AGENT_TIMEOUT_SECONDS = 22
  NON_DELIVERABLE_RESPONSES = [
    'conversation_handoff',
    'response_cancelled',
    Captain::Assistant::AgentRunnerService::PROVIDER_ERROR_RESPONSE
  ].freeze
  DEFAULT_USAGE = { 'prompt_tokens' => 0, 'completion_tokens' => 0, 'total_tokens' => 0 }.freeze

  module AgentCatalogHelpers
    private

    def init_agent_catalog!(assistant)
      @assistant = assistant
      @agents_by_id = {}
      @agents_by_name = {}
      @working_agents = []
      index_agents!
      @active_agent = summary_for(@assistant)
      record_working_agent(@active_agent, role: 'entry')
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

    def index_agents!
      graph_actors.each { |actor| register_actor(actor) }
    end

    def graph_actors
      actors = @assistant.persisted? ? Captain::AgentGraph.new(@assistant, inbox: @conversation&.inbox).agents : [@assistant]
      (Array(actors) + [@assistant]).compact.uniq(&:id)
    rescue StandardError
      [@assistant].compact
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
      entry['role'] = role if role.present? && entry['role'] == 'entry'
      entry
    end

    def normalize_name(value)
      value.to_s.strip.downcase
    end
  end

  module CouncilTrackerHelpers
    private

    def capture_council_plan!(context)
      parts = Array(context&.dig(:part_plan, :parts))
      return false if parts.blank?

      parts.each { |part| register_planned_part(part) }
      true
    end

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

    def council_snapshot
      return if @council_parts.empty?

      { 'active' => true, 'parts' => @council_parts.values.map(&:dup) }
    end

    def sanitize_text(value)
      text = value.to_s.strip
      return if text.blank?

      sanitized = Captain::ToolTraceBuilder.sanitize_payload(text)
      sanitized.is_a?(Hash) ? sanitized['preview'].to_s : sanitized.to_s
    end

    def register_planned_part(part)
      part_id = part['id'].to_s
      return if part_id.blank?

      part_actor = agent_by_id(part['executor_agent_id'])
      record_working_agent(part_actor, role: 'council') if part_actor.present?
      @council_parts[part_id] = {
        'id' => part['id'],
        'fragment' => sanitize_text(part['fragment']),
        'patient' => sanitize_text(part['patient']),
        'relation' => part['relation'].to_s.presence,
        'status' => 'planned',
        'agent' => part_actor
      }.compact
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

    def initialize(assistant:, conversation:, user:)
      @conversation = conversation
      @user = user
      @monitor = Monitor.new
      @council_parts = {}
      @tool_trace_steps = []
      @sequence = 0
      @handoffs = []
      @reasoning = nil
      @phase = 'thinking'
      init_agent_catalog!(assistant)
    end

    def callbacks
      {
        on_agent_thinking: method(:handle_agent_thinking),
        on_tool_start: method(:handle_tool_start),
        on_tool_progress: method(:handle_tool_progress),
        on_tool_complete: method(:handle_tool_complete),
        on_agent_handoff: method(:handle_agent_handoff),
        on_llm_call_complete: method(:handle_llm_call_complete)
      }
    end

    def broadcast_initial!
      @monitor.synchronize { broadcast_progress! }
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
          'council' => council_snapshot,
          'handoffs' => @handoffs.presence,
          'agent_tasks' => Array(payload[:agent_tasks]).presence
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
          activate_agent!(actor)
        end
        broadcast_progress!
      end
    end

    def handle_tool_start(tool_name, args = nil, context_wrapper = nil)
      @monitor.synchronize do
        actor = actor_from_context(context_wrapper)
        in_council = part_run?(context_wrapper)
        record_working_agent(actor, role: in_council ? 'council' : nil)
        @phase = in_council ? 'council_running' : 'tool_running'
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
        @phase = 'council_running' if tool_name.to_s == 'plan_request' && capture_council_plan!(context_wrapper&.context)
        broadcast_progress!
      end
    end

    def handle_agent_handoff(from_name, to_name, reason = nil, context_wrapper = nil)
      @monitor.synchronize do
        from_actor = agent_by_name(from_name) || @active_agent
        to_actor = agent_by_name(to_name) || actor_from_context(context_wrapper, to_name)
        record_working_agent(from_actor)
        activate_agent!(to_actor, role: 'handoff')
        @phase = 'handoff'
        @handoffs << build_handoff_entry(from_actor, to_actor, from_name, to_name, reason)
        broadcast_progress!
      end
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
      token = @user&.pubsub_token
      return if token.blank?

      ActionCable.server.broadcast(token, { event: PROGRESS_EVENT, data: progress_payload })
    rescue StandardError => e
      Rails.logger.debug { "[CAPTAIN][ReplySuggestionService] Progress broadcast skipped: #{e.message}" }
    end

    def progress_payload
      {
        account_id: @conversation&.account_id,
        conversation_id: @conversation&.display_id,
        conversation_record_id: @conversation&.id,
        phase: @phase,
        active_agent: @active_agent,
        working_agents: @working_agents,
        handoffs: @handoffs.presence,
        council: council_snapshot,
        captain_trace: Captain::ToolTraceBuilder.payload(
          @tool_trace_steps,
          reasoning: @reasoning.presence || combined_council_reasoning
        )
      }.compact
    end
  end

  def perform_reply_suggestion
    assistant = entry_assistant_for_suggestion
    return super if assistant.blank?

    perform_agent_reply_suggestion(assistant) || super
  end

  private

  def entry_assistant_for_suggestion
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

  def perform_agent_reply_suggestion(assistant)
    return { error: I18n.t('captain.api_key_missing'), error_code: 401 } unless api_key_configured?

    trace_collector = TraceCollector.new(assistant: assistant, conversation: conversation, user: user)
    trace_collector.broadcast_initial!

    raw_response = Llm::EventBus.with_context(user_id: user&.id) do
      Timeout.timeout(SUGGESTION_AGENT_TIMEOUT_SECONDS) do
        Captain::Assistant::AgentRunnerService.new(
          assistant: assistant,
          conversation: conversation,
          source: 'reply_suggestion',
          callbacks: trace_collector.callbacks
        ).generate_response(message_history: suggestion_message_history(assistant))
      end
    end

    build_agent_suggestion_result(raw_response, trace_collector)
  rescue StandardError => e
    Rails.logger.warn("[CAPTAIN][ReplySuggestionService] Agent suggestion fallback: #{e.class}: #{e.message}")
    nil
  end

  def build_agent_suggestion_result(raw_response, trace_collector = nil)
    payload = raw_response.to_h.with_indifferent_access
    content = payload[:response].to_s.strip
    return if non_deliverable_agent_payload?(payload, content)

    result = {
      message: content,
      usage: payload[:usage].presence || DEFAULT_USAGE,
      request_id: payload[:captain_request_id].presence
    }.compact
    attach_trace_and_meta!(result, payload, trace_collector) if trace_collector
    return result unless build_follow_up_context?

    result.merge(follow_up_context: build_follow_up_context([{ role: 'user', content: formatted_conversation }], result))
  end

  def attach_trace_and_meta!(result, payload, trace_collector)
    trace = trace_collector.captain_trace(payload)
    meta = trace_collector.suggestion_meta(payload)
    result[:captain_trace] = trace if trace.present?
    result[:suggestion_meta] = meta if meta.present?
  end

  def non_deliverable_agent_payload?(payload, content)
    content.blank? ||
      NON_DELIVERABLE_RESPONSES.include?(content) ||
      payload[:error_class].present? ||
      payload.values_at(:moderation_blocked, :response_suppressed, :response_cancelled).include?(true)
  end

  def suggestion_message_history(assistant)
    history = suggestion_messages(assistant).map { |message| build_suggestion_history_entry(message, assistant) }
    history << { role: 'user', content: FALLBACK_USER_PROMPT } if history.none? { |entry| entry[:role] == 'user' }
    history
  end

  def suggestion_messages(assistant)
    limit = assistant.history_message_limit_value
    scope = Captain::Conversation::ControlService
            .messages_scope(conversation)
            .where(message_type: [:incoming, :outgoing])
            .where(private: false)
    return scope.reorder(created_at: :asc, id: :asc).to_a unless limit.positive?

    scope.reorder(created_at: :desc, id: :desc).limit(limit).to_a.reverse
  end

  def build_suggestion_history_entry(message, assistant)
    entry = {
      content: Captain::OpenAiMessageBuilderService.new(message: message, assistant: assistant).generate_content,
      role: message.message_type == 'incoming' ? 'user' : 'assistant'
    }
    agent_name = message.additional_attributes.to_h['agent_name'].presence
    entry[:agent_name] = agent_name if agent_name.present?
    entry
  end
end
