# frozen_string_literal: true

class Captain::Runtime::Agent
  attr_reader :name, :instructions, :model, :tools, :handoff_agents, :temperature, :response_schema, :headers, :params
  attr_accessor :context_preparer, :assistant_id
  attr_writer :tool_ids

  def initialize(name:, instructions: nil, model: LlmConstants::DEFAULT_MODEL, tools: [], handoff_agents: [],
                 temperature: 0.7, response_schema: nil, headers: nil, params: nil, read_only_tools: false, suggestion_tools: false)
    @name = name
    @instructions = instructions
    @model = model
    @tools = tools.dup.freeze
    @handoff_agents = []
    @temperature = temperature
    @response_schema = response_schema
    @headers = Captain::Runtime::HashNormalizer.normalize(headers, label: 'headers', freeze_result: true)
    @params = Captain::Runtime::HashNormalizer.normalize(params, label: 'params', freeze_result: true)
    @read_only_tools = ActiveModel::Type::Boolean.new.cast(read_only_tools)
    @suggestion_tools = ActiveModel::Type::Boolean.new.cast(suggestion_tools)
    @mutex = Mutex.new

    register_handoffs(*handoff_agents) if handoff_agents.any?
  end

  def read_only_tools?
    @read_only_tools == true
  end

  def suggestion_tools?
    @suggestion_tools == true
  end

  def register_handoffs(*agents)
    @mutex.synchronize do
      @handoff_agents.concat(agents.flatten.compact.reject { |agent| agent.equal?(self) || agent.name == name })
      @handoff_agents.uniq!
    end
    self
  end

  # The names of the tools the agent acts with (the transfer tool of a colleague describes what the colleague can do from them).
  def tool_ids
    return Array(@tool_ids) if defined?(@tool_ids) && @tool_ids

    tools.filter_map { |tool| tool.name.to_s.presence if tool.respond_to?(:name) }
  end

  def get_system_prompt(context)
    case instructions
    when String
      instructions
    when Proc
      instructions.call(context)
    end
  end
end
