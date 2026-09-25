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

  def perform(_tool_context, **_params)
    # A subprocess can perform network writes even when its manifest says it
    # does not need network. It must not run inside the Captain owner lock (up
    # to 30s) or after takeover without a remote idempotency contract.
    Captain::ToolResult.failure_output(
      error: 'Captain skill scripts require an isolated, fenced execution contract',
      audit: { failure_stage: 'policy', failure_reason: 'unsafe_script_execution' }
    )
  end

  private

  attr_reader :tool_definition

  def script
    @script ||= Captain::SkillCatalog.script_for_tool_id(tool_definition[:id], account: assistant.account)
  end
end
