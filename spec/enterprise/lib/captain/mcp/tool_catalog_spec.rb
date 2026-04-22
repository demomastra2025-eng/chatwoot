require 'rails_helper'

RSpec.describe Captain::Mcp::ToolCatalog do
  describe '.available_tools_for' do
    let(:account) { create(:account) }
    let(:assistant) { create(:captain_assistant, account: account) }
    let!(:own_server) { create(:captain_mcp_server, account: account, slug: 'own_server') }
    let!(:other_server) { create(:captain_mcp_server, account: create(:account), slug: 'other_server') }

    before do
      allow_any_instance_of(described_class::DiscoveryService).to receive(:tools) do |service|
        server = service.instance_variable_get(:@mcp_server)
        [
          {
            id: "mcp__#{server.slug}__lookup",
            title: "#{server.slug} lookup",
            description: 'Lookup data',
            mcp_tool_name: 'lookup',
            input_schema: { 'type' => 'object', 'properties' => {} }
          }
        ]
      end
    end

    it 'returns MCP tools only from the assistant account' do
      tool_ids = described_class.available_tools_for(assistant, Captain::ToolAccess::SCOPE_AGENT).pluck(:id)

      expect(tool_ids).to include('mcp__own_server__lookup')
      expect(tool_ids).not_to include('mcp__other_server__lookup')
    end
  end
end
