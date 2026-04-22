require 'rails_helper'

RSpec.describe Captain::ToolCatalog do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }

  describe '.available_tools_for' do
    it 'uses the registry as the built-in source of truth for agent tools' do
      tool_ids = described_class.available_tools_for(assistant, Captain::ToolAccess::SCOPE_AGENT).pluck(:id)

      expect(tool_ids).to include('faq_lookup', 'handoff', 'create_deal')
    end

    it 'includes enabled custom tools for the requested scope' do
      custom_tool = create(:captain_custom_tool, account: account)

      agent_tool_ids = described_class.available_tools_for(assistant, Captain::ToolAccess::SCOPE_AGENT).pluck(:id)
      assistant_tool_ids = described_class.available_tools_for(assistant, Captain::ToolAccess::SCOPE_ASSISTANT).pluck(:id)

      expect(agent_tool_ids).to include(custom_tool.slug)
      expect(assistant_tool_ids).to include(custom_tool.slug)
    end

    it 'does not expose account-private custom tools from a different account' do
      own_tool = create(:captain_custom_tool, account: account, slug: 'custom_own-tool')
      other_tool = create(:captain_custom_tool, account: create(:account), slug: 'custom_other-tool')

      agent_tool_ids = described_class.available_tools_for(assistant, Captain::ToolAccess::SCOPE_AGENT).pluck(:id)
      assistant_tool_ids = described_class.available_tools_for(assistant, Captain::ToolAccess::SCOPE_ASSISTANT).pluck(:id)

      expect(agent_tool_ids).to include(own_tool.slug)
      expect(agent_tool_ids).not_to include(other_tool.slug)
      expect(assistant_tool_ids).to include(own_tool.slug)
      expect(assistant_tool_ids).not_to include(other_tool.slug)
    end

    it 'includes discovered MCP tools for the requested scope' do
      create(:captain_mcp_server, account: account)
      allow(Captain::Mcp::ToolCatalog).to receive(:available_tools_for)
        .with(assistant, Captain::ToolAccess::SCOPE_AGENT)
        .and_return([
                      {
                        id: 'mcp__github_mcp__list_issues',
                        title: 'List issues',
                        description: 'List repository issues',
                        provider: 'mcp',
                        mcp_server_id: 123,
                        mcp_tool_name: 'list_issues'
                      }
                    ])

      tool_ids = described_class.available_tools_for(assistant, Captain::ToolAccess::SCOPE_AGENT).pluck(:id)

      expect(tool_ids).to include('mcp__github_mcp__list_issues')
    end

    it 'deduplicates tool definitions by id' do
      allow(Captain::ToolRegistry).to receive(:tools_for_scope)
        .with(Captain::ToolAccess::SCOPE_AGENT)
        .and_return(
          [
            { id: 'faq_lookup', title: 'FAQ Lookup', description: 'A', allowed_scopes: ['agent'] },
            { id: 'faq_lookup', title: 'FAQ Lookup', description: 'B', allowed_scopes: ['agent'] }
          ]
        )

      tools = described_class.available_tools_for(assistant, Captain::ToolAccess::SCOPE_AGENT)

      expect(tools.pluck(:id)).to eq(['faq_lookup'])
    end
  end

  describe '.build_tool' do
    it 'builds a built-in assistant tool using the registry resolver' do
      tool = described_class.build_tool(
        { id: 'search_documentation', custom: false },
        assistant: assistant,
        scope_name: Captain::ToolAccess::SCOPE_ASSISTANT,
        user: nil,
        conversation: nil
      )

      expect(tool).to be_a(Captain::Tools::SearchDocumentationService)
    end

    it 'builds a custom assistant tool via the custom tool record' do
      custom_tool = create(:captain_custom_tool, account: account)

      tool = described_class.build_tool(
        { id: custom_tool.slug, custom: true },
        assistant: assistant,
        scope_name: Captain::ToolAccess::SCOPE_ASSISTANT,
        user: nil,
        conversation: nil
      )

      expect(tool).to be_a(Captain::Tools::Copilot::CustomHttpTool)
    end

    it 'builds a custom agent tool via the dynamic public tool path' do
      custom_tool = create(:captain_custom_tool, account: account)

      tool = described_class.build_tool(
        { id: custom_tool.slug, custom: true },
        assistant: assistant,
        scope_name: Captain::ToolAccess::SCOPE_AGENT
      )

      expect(tool).to be_a(Captain::Tools::HttpTool)
    end

    it 'builds an MCP assistant tool via the provider path' do
      mcp_server = create(:captain_mcp_server, account: account)

      tool = described_class.build_tool(
        {
          id: 'mcp__github_mcp__list_issues',
          provider: 'mcp',
          mcp_server_id: mcp_server.id,
          mcp_tool_name: 'list_issues',
          input_schema: { 'type' => 'object', 'properties' => {} }
        },
        assistant: assistant,
        scope_name: Captain::ToolAccess::SCOPE_ASSISTANT,
        user: nil,
        conversation: nil
      )

      expect(tool).to be_a(Captain::Tools::Copilot::McpTool)
    end
  end

  describe '.summary_for' do
    it 'formats tool summaries consistently' do
      summary = described_class.summary_for(
        [
          { id: 'faq_lookup', description: 'Search FAQ responses' },
          { id: 'handoff', description: 'Hand off the conversation' }
        ]
      )

      expect(summary).to eq("- faq_lookup: Search FAQ responses\n- handoff: Hand off the conversation")
    end
  end
end
