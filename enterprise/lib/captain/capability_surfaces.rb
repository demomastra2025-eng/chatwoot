# frozen_string_literal: true

require Rails.root.join('enterprise/lib/onelink/mcp/captain_tool_adapter').to_s

# A read-only simulation using the actual binding readers. No persistence or tool
# execution occurs. The same assistant retains its account policy and runtime context.
class Captain::CapabilitySurfaces
  McpContext = Struct.new(:assistant, :account, :scope_name, keyword_init: true)

  def self.compare(assistant, scopes)
    original = assistant.config
    before = new(assistant).snapshot
    canonical = {
      'version' => Captain::Capabilities::VERSION,
      'scopes' => scopes.transform_values { |scope| { 'enabled' => scope[:enabled], 'tool_ids' => scope[:proposed_tool_ids] } }
    }
    begin
      assistant.config = original.to_h.merge(Captain::Capabilities::KEY => canonical)
      after = new(assistant).snapshot
      before.each_with_object({}) do |(surface, ids), differences|
        added = after.fetch(surface) - ids
        removed = ids - after.fetch(surface)
        differences[surface] = { added: added, removed: removed } if added.any? || removed.any?
      end
    ensure
      assistant.config = original
    end
  end

  def initialize(assistant)
    @assistant = assistant
  end

  def snapshot
    {
      allowed_agent: @assistant.allowed_agent_tool_ids.sort,
      prompt_agent: @assistant.prompt_runtime_agent_tools.pluck(:id).map(&:to_s).sort,
      voice: @assistant.voice_runtime_agent_tools.pluck(:id).map(&:to_s).sort,
      allowed_assistant: @assistant.allowed_assistant_tool_ids.sort
    }.merge(mcp_bindings)
  end

  private

  def mcp_bindings
    Captain::ToolAccess::SCOPE_ORDER.each_with_object({}) do |scope, result|
      context = McpContext.new(assistant: @assistant, account: @assistant.account, scope_name: scope)
      Onelink::Mcp::CaptainToolAdapter.new(auth_context: context).capability_bindings.each do |surface, ids|
        result["mcp_#{scope}_#{surface}".to_sym] = ids
      end
    end
  end
end
