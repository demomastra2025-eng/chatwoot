# frozen_string_literal: true

class Captain::Runtime::Agent
  attr_reader :name, :instructions, :model, :tools, :handoff_agents, :temperature, :response_schema, :headers, :params

  def initialize(name:, instructions: nil, model: LlmConstants::DEFAULT_MODEL, tools: [], handoff_agents: [],
                 temperature: 0.7, response_schema: nil, headers: nil, params: nil)
    @name = name
    @instructions = instructions
    @model = model
    @tools = tools.dup.freeze
    @handoff_agents = []
    @temperature = temperature
    @response_schema = response_schema
    @headers = Captain::Runtime::HashNormalizer.normalize(headers, label: 'headers', freeze_result: true)
    @params = Captain::Runtime::HashNormalizer.normalize(params, label: 'params', freeze_result: true)
    @mutex = Mutex.new

    register_handoffs(*handoff_agents) if handoff_agents.any?
  end

  def register_handoffs(*agents)
    @mutex.synchronize do
      @handoff_agents.concat(agents.flatten.compact.reject { |agent| agent.equal?(self) || agent.name == name })
      @handoff_agents.uniq!
    end
    self
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
