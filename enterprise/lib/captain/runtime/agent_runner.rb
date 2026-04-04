# frozen_string_literal: true

class Captain::Runtime::AgentRunner
  attr_reader :agents

  def initialize(agents)
    raise ArgumentError, 'At least one agent must be provided' if agents.empty?

    @agents = agents.dup.freeze
    @callbacks_mutex = Mutex.new
    @default_agent = agents.first
    @registry = build_registry(agents).freeze
    @callbacks = Captain::Runtime::CallbackManager::EVENT_TYPES.index_with { [] }
  end

  def run(input, context: {}, max_turns: Captain::Runtime::Runner::DEFAULT_MAX_TURNS, runtime_options: {})
    current_agent = determine_conversation_agent(context)

    Captain::Runtime::Runner.new.run(
      current_agent,
      input,
      **build_run_options(context, max_turns, runtime_options)
    )
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
    }.merge(runtime_options.symbolize_keys.slice(:llm_context, :headers, :params))
  end

  def determine_conversation_agent(context)
    history = context[:conversation_history] || []
    return @default_agent if history.empty?

    last_assistant_message = history.reverse.find do |msg|
      message_role(msg) == 'assistant' && message_agent_name(msg).present?
    end
    last_agent_name = message_agent_name(last_assistant_message) if last_assistant_message

    @registry[last_agent_name] || @default_agent
  end

  def message_role(message)
    (message[:role] || message['role']).to_s
  end

  def message_agent_name(message)
    message[:agent_name] || message['agent_name']
  end
end
