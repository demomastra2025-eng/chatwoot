# frozen_string_literal: true

# Runs the agent that answers a turn. The agent is always explicit: the router chose it (context[:current_agent], see
# Captain::Runtime::TurnDispatcher), or the channel has one agent only. Nothing here picks an agent from the history or falls back
# to a first or main agent.
class Captain::Runtime::AgentRunner
  attr_reader :agents

  def initialize(agents)
    raise ArgumentError, 'At least one agent must be provided' if agents.empty?

    @agents = agents.dup.freeze
    @callbacks_mutex = Mutex.new
    @registry = build_registry(agents).freeze
    @callbacks = Captain::Runtime::CallbackManager::EVENT_TYPES.index_with { [] }
  end

  def run(input, context: {}, max_turns: Captain::Runtime::Runner::DEFAULT_MAX_TURNS, runtime_options: {})
    Captain::Runtime::Runner.new.run(
      conversation_agent(context),
      input,
      **build_run_options(context, max_turns, runtime_options)
    )
  end

  # A council turn. council: { parts:, acting_agent_key:, reassigner: }: the participants the router chose answer their parts; the
  # acting agent is the one the turn runs as.
  def run_council(input, council:, context: {}, runtime_options: {})
    Captain::Runtime::Runner.new.run_council(
      fetch(council.fetch(:acting_agent_key)),
      input,
      parts: council.fetch(:parts), reassigner: council[:reassigner],
      **build_run_options(context, Captain::Runtime::Runner::DEFAULT_MAX_TURNS, runtime_options)
    )
  end

  def fetch(name)
    @registry[name.to_s] || raise(Captain::Runtime::Runner::AgentNotFoundError, "Agent '#{name}' not found in registry")
  end

  Captain::Runtime::CallbackManager::EVENT_TYPES.each do |event_type|
    define_method("on_#{event_type}") do |&block|
      return self unless block

      @callbacks_mutex.synchronize { @callbacks[event_type] << block }
      self
    end
  end

  private

  def build_registry(agents)
    agents.index_by(&:name)
  end

  def build_run_options(context, max_turns, runtime_options)
    {
      context: context,
      registry: @registry,
      max_turns: max_turns,
      callbacks: @callbacks
    }.merge(runtime_options.symbolize_keys.slice(:llm_context, :headers, :params, :account, :finalization_only, :continue_from_history))
  end

  def conversation_agent(context)
    name = context[:current_agent] || context['current_agent']
    return fetch(name) if name.present?
    return @agents.first if @agents.one?

    raise Captain::Runtime::Runner::AgentNotFoundError, 'No agent was chosen for this turn'
  end
end
