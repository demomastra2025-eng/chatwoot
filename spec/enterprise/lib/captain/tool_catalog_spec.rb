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
