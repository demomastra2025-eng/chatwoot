require 'ostruct'

# V1-compatible wrapper for custom HTTP tools.
#
# V2's HttpTool inherits from Agents::Tool and runs through perform(tool_context, **params),
# while the V1 RubyLLM pipeline calls execute(**params). This wrapper keeps the
# HTTP implementation shared and only adapts the invocation shape.
class Captain::Tools::CustomHttpTool < Captain::Tools::BaseTool
  prepend Captain::Tools::Instrumentation

  attr_reader :custom_tool

  def initialize(assistant, custom_tool, conversation: nil)
    @custom_tool = custom_tool
    @conversation = conversation
    super(assistant)
  end

  def active?
    @custom_tool.enabled?
  end

  def execute(**params)
    http_tool = Captain::Tools::HttpTool.new(assistant, @custom_tool)
    http_tool.perform(build_tool_context, **params)
  end

  private

  def build_tool_context
    state = { account_id: assistant.account_id, assistant_id: assistant.id }
    add_conversation_state(state) if @conversation
    OpenStruct.new(state: state)
  end

  def add_conversation_state(state)
    state[:conversation] = { id: @conversation.id, display_id: @conversation.display_id }
    state[:contact] = slice_record_attrs(@conversation.contact, :id, :email, :phone_number)
    state[:contact_inbox] = slice_record_attrs(@conversation.contact_inbox, :id, :hmac_verified)
  end

  def slice_record_attrs(record, *keys)
    record&.attributes&.symbolize_keys&.slice(*keys)
  end
end
