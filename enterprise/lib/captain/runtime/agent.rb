# frozen_string_literal: true

class Captain::Runtime::Agent
  attr_reader :name, :instructions, :instruction_parts, :model, :tools, :temperature, :response_schema, :headers, :params
  attr_accessor :context_preparer, :assistant_id
  attr_writer :tool_ids

  # instruction_parts: a proc that returns the system prompt as Captain::PromptParts (the stable text and the per-request text apart),
  # for an agent whose prompt has a part that changes from one request to the next. Without it the instructions are all stable.
  def initialize(name:, instructions: nil, model: LlmConstants::DEFAULT_MODEL, tools: [], # rubocop:disable Metrics/ParameterLists
                 temperature: 0.7, response_schema: nil, headers: nil, params: nil, read_only_tools: false, suggestion_tools: false,
                 instruction_parts: nil)
    @name = name
    @instructions = instructions
    @instruction_parts = instruction_parts
    @model = model
    @tools = tools.dup.freeze
    @temperature = temperature
    @response_schema = response_schema
    @headers = Captain::Runtime::HashNormalizer.normalize(headers, label: 'headers', freeze_result: true)
    @params = Captain::Runtime::HashNormalizer.normalize(params, label: 'params', freeze_result: true)
    @read_only_tools = ActiveModel::Type::Boolean.new.cast(read_only_tools)
    @suggestion_tools = ActiveModel::Type::Boolean.new.cast(suggestion_tools)
  end

  def read_only_tools?
    @read_only_tools == true
  end

  def suggestion_tools?
    @suggestion_tools == true
  end

  # The names of the tools the agent acts with.
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

  # The system prompt in the order the provider caches it: what is the same for every request first, what changes per request last.
  def get_system_prompt_parts(context)
    return @instruction_parts.call(context) if @instruction_parts

    Captain::PromptParts.stable_only(get_system_prompt(context))
  end
end
