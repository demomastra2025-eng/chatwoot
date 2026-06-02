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
    allow(Captain::ToolPolicy).to receive(:selection_metadata).and_return(
      required_features: [],
      required_permissions: [],
      risk_level: 'low',
      requires_confirmation: false,
      agent_high_risk: false
    )
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
  end
end
