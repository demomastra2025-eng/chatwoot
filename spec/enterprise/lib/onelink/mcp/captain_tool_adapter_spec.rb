# frozen_string_literal: true

require 'rails_helper'

require Rails.root.join('enterprise/lib/onelink/mcp/access_policy').to_s
require Rails.root.join('enterprise/lib/onelink/mcp/captain_tool_adapter').to_s

RSpec.describe Onelink::Mcp::CaptainToolAdapter do
  subject(:adapter) { described_class.new(auth_context: auth_context) }

  let(:account) { instance_double(Account, id: 42) }
  let(:user) { instance_double(User, id: 7) }
  let(:assistant_config) { {} }
  let(:assistant) do
    instance_double(
      Captain::Assistant,
      id: 99,
      config: assistant_config,
      persisted?: true
    )
  end
  let(:access_policy) { Onelink::Mcp::AccessPolicy.new(account: account, user: user, config: {}) }
  let(:auth_context) do
    instance_double(
      Onelink::Mcp::AuthContext,
      account: account,
      user: user,
      assistant: assistant,
      scope_name: Captain::ToolAccess::SCOPE_ASSISTANT,
      administrator?: true,
      mcp_access_policy: access_policy
    )
  end
  let(:tool_schema) do
    {
      type: 'object',
      properties: { query: { type: 'string' } },
      required: ['query']
    }
  end
  let(:available_tools) do
    [
      {
        id: 'allowed_tool',
        title: 'Allowed tool',
        description: 'Allowed by assistant policy',
        group_name: 'Knowledge',
        allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
        risk_level: 'low',
        idempotent: true,
        requires_confirmation: false,
        input_schema: tool_schema
      },
      {
        id: 'blocked_by_assistant_selection',
        title: 'Blocked by assistant selection',
        description: 'Available but not selected on the assistant',
        group_name: 'Admin',
        allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
        risk_level: 'low',
        idempotent: true,
        requires_confirmation: false,
        input_schema: tool_schema
      }
    ]
  end

  before do
    allow(Captain::ToolCatalog).to receive(:available_tools_for).and_return(available_tools)
    allow(Captain::ToolCatalog).to receive(:allowed_tools_for)
    allow(Captain::ToolPolicy).to receive(:execution_allowed?).and_return(true)
    allow(Captain::ToolPolicy).to receive(:selection_metadata) do |tool_definition|
      {
        required_features: [],
        required_permissions: [],
        risk_level: tool_definition[:risk_level] || 'low',
        requires_confirmation: tool_definition[:requires_confirmation] || false,
        agent_high_risk: %w[high custom].include?(tool_definition[:risk_level].to_s)
      }
    end
    allow(Captain::ToolExecutionAuditService).to receive(:record)
  end

  describe '#catalog_entries' do
    it 'does not run per-tool execution policy for administrator settings catalogs' do
      entries = adapter.catalog_entries

      expect(entries.pluck(:id)).to contain_exactly('allowed_tool', 'blocked_by_assistant_selection')
      expect(Captain::ToolCatalog).to have_received(:available_tools_for).once
      expect(Captain::ToolPolicy).not_to have_received(:execution_allowed?)
    end
  end

  describe '#tools' do
    context 'when assistant tool access is not explicitly configured' do
      it 'uses the available tool catalog once instead of resolving it again through allowed_tools_for' do
        tool_names = adapter.tools.pluck(:name)

        expect(tool_names).to contain_exactly('allowed_tool', 'blocked_by_assistant_selection')
        expect(Captain::ToolCatalog).to have_received(:available_tools_for).once
        expect(Captain::ToolCatalog).not_to have_received(:allowed_tools_for)
      end
    end

    context 'when assistant tool access is explicitly configured' do
      let(:assistant_config) do
        {
          'tool_access' => {
            Captain::ToolAccess::SCOPE_ASSISTANT => {
              'enabled' => true,
              'tool_ids' => ['allowed_tool']
            }
          }
        }
      end

      it 'filters against the configured assistant tool ids without recomputing the full catalog' do
        tool_names = adapter.tools.pluck(:name)

        expect(tool_names).to eq(['allowed_tool'])
        expect(Captain::ToolCatalog).to have_received(:available_tools_for).once
        expect(Captain::ToolCatalog).not_to have_received(:allowed_tools_for)
      end
    end

    context 'when a medium-risk Captain tool mutates state but is marked idempotent' do
      let(:available_tools) do
        [
          {
            id: 'update_priority',
            title: 'Update Priority',
            description: 'Update the priority of the current conversation',
            group_name: 'Conversations',
            allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
            risk_level: 'medium',
            idempotent: true,
            requires_confirmation: false,
            input_schema: {
              type: 'object',
              properties: { priority: { type: 'string' } },
              required: ['priority']
            }
          }
        ]
      end

      it 'adds an MCP confirmation requirement and still advertises the tool as destructive' do
        tool = adapter.tools.first

        expect(tool.dig(:_meta, :requires_confirmation)).to be(true)
        expect(tool.dig(:inputSchema, 'properties')).to include('_confirm')
        expect(tool.dig(:inputSchema, 'required')).to include('_confirm')
        expect(tool.dig(:annotations, :idempotentHint)).to be(true)
        expect(tool.dig(:annotations, :destructiveHint)).to be(true)
      end
    end
  end

  describe '#call_tool' do
    before do
      allow(Captain::ToolRegistry).to receive(:definition_for).and_return(nil)
    end

    it 'returns a machine-readable not_active error when the runtime tool is inactive' do
      inactive_tool = instance_double(Captain::Tools::BaseTool, active?: false)

      allow(Captain::ToolCatalog).to receive(:build_tool).and_return(inactive_tool)

      result = adapter.call_tool(name: 'allowed_tool', arguments: { query: 'shipping' })

      expect(result[:isError]).to be(true)
      expect(result[:structuredContent]).to include(
        code: 'not_active',
        tool: 'allowed_tool',
        message: "Tool 'allowed_tool' is not active for this workspace"
      )
      expect(result.dig(:content, 0, :text)).to include('not active')
    end

    it 'does not expose raw ActiveRecord exception class names to external MCP clients' do
      failing_tool = Class.new do
        def active?
          true
        end

        def execute(**)
          raise ActiveRecord::RecordNotFound, "Couldn't find Captain::Campaign with 'id'=404"
        end
      end.new

      allow(Captain::ToolCatalog).to receive(:build_tool).and_return(failing_tool)

      result = adapter.call_tool(name: 'allowed_tool', arguments: { query: 'missing' })

      expect(result[:isError]).to be(true)
      expect(result[:structuredContent]).to include(
        code: 'not_found',
        message: 'Resource could not be found'
      )
      expect(result.dig(:content, 0, :text)).not_to include('ActiveRecord::RecordNotFound')
      expect(result.dig(:content, 0, :text)).not_to include('Captain::Campaign')
    end
  end
end
