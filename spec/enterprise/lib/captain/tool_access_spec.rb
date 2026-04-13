require 'rails_helper'

RSpec.describe Captain::ToolAccess do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }

  describe '.normalized_access_for' do
    it 'does not enable MCP tools by default for assistant scope' do
      allow(assistant).to receive(:available_agent_tools).and_return([])
      allow(assistant).to receive(:available_assistant_tools).and_return([
                                                                          {
                                                                            id: 'search_documentation',
                                                                            title: 'Search documentation'
                                                                          },
                                                                          {
                                                                            id: 'mcp__github__list_issues',
                                                                            title: 'List issues',
                                                                            provider: 'mcp',
                                                                            selected_by_default: false
                                                                          }
                                                                        ])

      access = described_class.normalized_access_for(assistant)

      expect(access.dig(Captain::ToolAccess::SCOPE_ASSISTANT, 'enabled')).to be(true)
      expect(access.dig(Captain::ToolAccess::SCOPE_ASSISTANT, 'tool_ids')).to eq(['search_documentation'])
    end

    it 'keeps explicitly configured MCP tools selected' do
      assistant.config = {
        'tool_access' => {
          Captain::ToolAccess::SCOPE_ASSISTANT => {
            'enabled' => true,
            'tool_ids' => ['mcp__github__list_issues']
          }
        }
      }

      allow(assistant).to receive(:available_agent_tools).and_return([])
      allow(assistant).to receive(:available_assistant_tools).and_return([
                                                                          {
                                                                            id: 'mcp__github__list_issues',
                                                                            title: 'List issues',
                                                                            provider: 'mcp',
                                                                            selected_by_default: false
                                                                          }
                                                                        ])

      access = described_class.normalized_access_for(assistant)

      expect(access.dig(Captain::ToolAccess::SCOPE_ASSISTANT, 'tool_ids')).to eq(['mcp__github__list_issues'])
    end
  end
end
