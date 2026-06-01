# frozen_string_literal: true

class Captain::Tools::SkillScriptTool < Captain::Tools::BasePublicTool
  def initialize(assistant, tool_definition)
    super(assistant)
    @tool_definition = tool_definition.with_indifferent_access
  end

  def name
    tool_definition[:id]
  end

  def description
    tool_definition[:description]
  end

  def parameters
    @parameters ||= Captain::Mcp::ParameterBuilder.from_schema(params_schema)
  end

  def params_schema
    script[:parameters_schema]
  end

  def active?
    script.present?
  end

  def perform(tool_context, **params)
    Captain::SkillScriptRunner.new(
      script: script,
      assistant: assistant,
      tool_context: tool_context,
      params: params
    ).call
  end

  private

  attr_reader :tool_definition

  def script
    @script ||= Captain::SkillCatalog.script_for_tool_id(tool_definition[:id], account: assistant.account)
  end
end
