# frozen_string_literal: true

class Captain::AgentRunContext
  def initialize(entry:, conversation: nil, playground: nil, fence: {})
    @entry, @conversation, @playground = entry, conversation, playground
    @graph = Captain::AgentGraph.new(entry)
    @session = Captain::Conversation::AgentSession.new(entry: entry, conversation: conversation, playground: playground, fence: fence)
  end

  attr_reader :graph

  def prepare(context)
    context.delete(:captain_faq_outcome)
    context[:agent_request_id] ||= SecureRandom.uuid
    @entry_playground_overrides = context.fetch(:state, {}).slice(:playground_thinking_effort)
    saved = @session.read
    current = graph.find(saved['current_assistant_id']) || graph.entry
    raise ArgumentError, 'The entry agent is disabled' unless graph.find(current.id)

    if saved['current_assistant_id'].present? && current.id != saved['current_assistant_id'].to_i
      Captain::Runtime::CoordinationEvents.publish(
        'agent.reset', context: context, reason: 'agent_unavailable',
        from_agent_id: saved['current_assistant_id'], to_agent_id: current.id
      )
    end

    context[:agent_graph] = graph.payload
    context[:agent_session] = @session
    context[:agent_tasks] = saved['tasks'] || []
    context[:agent_tasks].each do |task|
      next if Captain::Runtime::TaskQueue::TERMINAL.include?(task['status']) || graph.find(task['assistant_id'])

      task['status'] = 'waiting'
      task['result'] = 'The assigned agent is unavailable. Explain the remaining request or cancel it if the customer no longer needs it.'
    end
    context[:current_agent] = "assistant_#{current.id}"
    context[:state][:entry_assistant_id] = @entry.id
    context[:state][:agent_graph_ids] = graph.agents.map(&:id)
    activate(current, context)
    context
  end

  def activate(actor, context)
    state = context[:state] ||= {}
    previous_id = state[:assistant_id]
    state[:assistant_id] = actor.id
    state[:assistant_config] = actor.config
    prior_runtime = state[:captain_runtime]
    state[:captain_runtime] = Captain::AssistantSafetyPreferences.for(assistant: actor, feature: :assistant)
    state[:captain_runtime]['assistant_thinking_effort'] = actor.config['thinking_effort'] if actor.config['thinking_effort'].present?
    state.delete(:playground_thinking_effort)
    if actor.id == @entry.id && @entry_playground_overrides&.key?(:playground_thinking_effort)
      state[:playground_thinking_effort] = @entry_playground_overrides[:playground_thinking_effort]
      state[:captain_runtime]['assistant_thinking_effort'] = state[:playground_thinking_effort]
    elsif actor.id == @entry.id && previous_id == actor.id && prior_runtime&.key?('assistant_thinking_effort') && @playground
      state[:captain_runtime]['assistant_thinking_effort'] = prior_runtime['assistant_thinking_effort']
    end
    state[:prompt_context] = actor.prompt_context_state(state)
    context[:current_agent] = "assistant_#{actor.id}"
    context[:acting_assistant_id] = actor.id
    @playground&.activate_agent!(actor)
    state[:playground] = @playground.context_reference if @playground
    Current.executed_by = actor if @conversation
    if previous_id.present? && previous_id != actor.id
      # A destination receives the public dialogue and explicit task outcomes,
      # never another agent's raw private retrievals or provider reasoning.
      context[:conversation_history] = public_history(context[:conversation_history])
      clear_actor_caches(context)
    end
    Captain::Runtime::TaskQueue.new(context).on_handoff
  end

  def runtime_agents(overrides: {})
    registry = graph.agents.index_with do |actor|
      # Playground model controls affect the selected agent only.
      options = actor.id == @entry.id ? overrides : {}
      actor.agent(**options).tap do |runtime_agent|
        runtime_agent.context_preparer = ->(wrapper) { activate(actor, wrapper.context) }
        runtime_agent.assistant_id = actor.id
      end
    end
    registry.each do |actor, runtime_agent|
      actor.handoff_targets.each do |target|
        runtime_agent.register_handoffs(registry[target]) if registry[target]
      end
    end
    registry.values
  end

  private

  def public_history(history)
    Array(history).filter_map do |raw|
      message = raw.to_h.with_indifferent_access
      next unless %w[user assistant].include?(message[:role].to_s)
      next if message[:tool_calls].present?

      public = message.slice(:role, :content, :agent_name).symbolize_keys
      public[:content] = public_response(public[:content]) if message[:role].to_s == 'assistant'
      public
    end
  end

  def public_response(content)
    parsed = content.is_a?(String) ? JSON.parse(content) : content
    return parsed['response'].to_s if parsed.is_a?(Hash) && parsed.key?('response')

    content
  rescue JSON::ParserError
    content
  end

  def clear_actor_caches(context)
    %i[captain_v2_tool_result_cache captain_v2_tool_failure_cache captain_faq_outcome].each { |key| context.delete(key) }
  end
end
