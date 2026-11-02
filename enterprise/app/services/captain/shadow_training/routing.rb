# frozen_string_literal: true

class Captain::ShadowTraining::Routing
  def self.select(run)
    snapshot = run.snapshot
    rows = snapshot.fetch('routing_agents')
    return [nil, 'no_routing_candidates'] if rows.empty?

    graph = Captain::AgentGraph.new(Captain::ChannelScope.for_conversation(run.conversation))
    return [nil, 'routing_configuration_changed'] unless graph.candidates.map(&:id).sort == rows.pluck('id').sort
    return [graph.find(rows.first.fetch('id')), nil] if rows.one?

    decision = Captain::ShadowTraining::DataScope.with(run) { decide(run, rows) }
    return [nil, "routing_#{decision.kind}_requires_review"] unless decision.agent? || decision.stay?

    [graph.find(decision.agent_id), nil]
  end

  def self.decide(run, rows)
    Captain::ShadowTraining::Eligibility.ensure_run!(run)
    context = { conversation_history: run.snapshot.fetch('history'), routing_current_agent_id: run.snapshot['current_assistant_id'],
                state: { source: 'shadow_training' } }
    routing = Captain::Runtime::RoutingSnapshot.from_context(context, candidates: [])
    # Rehydrate the already captured cards, rather than reading changed routing instructions or live sessions.
    routing = Captain::Runtime::RoutingSnapshot.new(
      agents: rows.map { |row| Captain::Runtime::RoutingSnapshot::Agent.new(**row.symbolize_keys) },
      latest_message: routing.latest_message, recent_messages: routing.recent_messages,
      current_agent_id: run.snapshot['current_assistant_id'], source: 'shadow_training', human_available: true
    )
    decision = Captain::Runtime::DecisionRouter.new(
      routing, account: run.account, request: { session_id: "shadow:#{run.id}" },
               observability: { account_id: run.account_id, shadow_training_run_id: run.id, source: 'shadow_training' }
    ).decide
    Captain::ShadowTraining::Eligibility.ensure_run!(run)
    decision
  end
end
