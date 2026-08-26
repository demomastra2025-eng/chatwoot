require 'rails_helper'

RSpec.describe Captain::ToolAccess do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }

  describe '.normalized_access_for' do
    it 'does not grant web capabilities to agents by default' do
      allow(assistant).to receive(:available_agent_tools).and_return(
        %w[faq_lookup web_search web_scrape_url handoff].map { |id| { id: id } }
      )
      allow(assistant).to receive(:available_assistant_tools).and_return([])

      access = described_class.normalized_access_for(assistant)

      expect(access.dig(Captain::ToolAccess::SCOPE_AGENT, 'tool_ids')).to contain_exactly('faq_lookup', 'handoff')
    end

    it 'does not enable MCP tools by default for assistant scope' do
      allow(assistant).to receive(:available_agent_tools).and_return([])
      allow(assistant).to receive(:available_assistant_tools).and_return(
        [
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
        ]
      )

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
      allow(assistant).to receive(:available_assistant_tools).and_return(
        [
          {
            id: 'mcp__github__list_issues',
            title: 'List issues',
            provider: 'mcp',
            selected_by_default: false
          }
        ]
      )

      access = described_class.normalized_access_for(assistant)

      expect(access.dig(Captain::ToolAccess::SCOPE_ASSISTANT, 'tool_ids')).to eq(['mcp__github__list_issues'])
    end
  end

  describe '.allowed_tool_ids_for' do
    it 'resolves only the requested scope' do
      assistant.config = {
        'tool_access' => {
          Captain::ToolAccess::SCOPE_AGENT => {
            'enabled' => true,
            'tool_ids' => ['faq_lookup']
          }
        }
      }
      allow(assistant).to receive(:available_agent_tools).and_return([{ id: 'faq_lookup' }])
      expect(assistant).not_to receive(:available_assistant_tools)

      ids = described_class.allowed_tool_ids_for(
        assistant,
        Captain::ToolAccess::SCOPE_AGENT,
        fallback_ids: ['faq_lookup']
      )

      expect(ids).to eq(['faq_lookup'])
    end
  end

  describe '.per_assistant_web_tool_enabled?' do
    it 'allows only explicitly selected web tools' do
      assistant.config = {
        'tool_access' => {
          'agent' => { 'enabled' => true, 'tool_ids' => ['web_search'] }
        }
      }

      expect(described_class.per_assistant_web_tool_enabled?(assistant, 'web_search', scope_name: 'agent')).to be(true)
      expect(described_class.per_assistant_web_tool_enabled?(assistant, 'web_scrape_url', scope_name: 'agent')).to be(false)
    end

    it 'blocks web tools when their scope is disabled' do
      assistant.config = {
        'tool_access' => {
          'agent' => { 'enabled' => false, 'tool_ids' => ['web_search'] }
        }
      }

      expect(described_class.per_assistant_web_tool_enabled?(assistant, 'web_search', scope_name: 'agent')).to be(false)
    end

    it 'preserves the legacy feature_web fallback until tool access is saved' do
      assistant.config = { 'feature_web' => true }

      expect(described_class.per_assistant_web_tool_enabled?(assistant, 'web_search', scope_name: 'agent')).to be(true)
    end
  end
end
