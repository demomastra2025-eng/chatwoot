require 'rails_helper'

RSpec.describe Captain::ToolAccess do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }

  describe '.normalized_access_for' do
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

  describe '.definitions_for' do
    it 'marks capability tools as nonmentionable without hiding ordinary tool choices' do
      allow(assistant).to receive(:available_agent_tools).and_return([
        { id: 'faq_lookup' }, { id: 'handoff' }, { id: 'create_deal' },
        { id: 'custom_orders', provider: 'custom' }, { id: 'future_capability', capability_tool: true }
      ])
      allow(assistant).to receive(:available_assistant_tools).and_return([])
      tools = described_class.definitions_for(assistant).index_by { |tool| tool[:id] }
      expect(tools['faq_lookup'][:mentionable]).to be(false)
      expect(tools['handoff'][:mentionable]).to be(false)
      expect(tools['future_capability'][:mentionable]).to be(false)
      expect(tools['create_deal'][:mentionable]).to be(true)
      expect(tools['custom_orders'][:mentionable]).to be(true)
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

  describe 'the shared read layer' do
    let(:only_handoff) { { 'tool_access' => { 'agent' => { 'enabled' => true, 'tool_ids' => ['handoff'] } } } }

    def agent_tool_ids(record)
      described_class.allowed_tool_ids_for(record, Captain::ToolAccess::SCOPE_AGENT, fallback_ids: [])
    end

    it 'gives a customer-facing agent the FAQ lookup and the service catalog whatever the clinic selected' do
      account.enable_features!('scheduling')
      assistant.update!(config: only_handoff)

      ids = agent_tool_ids(assistant)

      expect(ids).to include('handoff', 'faq_lookup', 'search_scheduling_services')
      expect(ids).to eq(ids.uniq)
      expect(described_class.normalized_access_for(assistant).dig(Captain::ToolAccess::SCOPE_AGENT, 'tool_ids'))
        .to include('faq_lookup', 'search_scheduling_services')
    end

    it 'adds read tools only: the writing tools and the patient-data tools stay as the clinic configured them' do
      account.enable_features!('scheduling')
      assistant.update!(config: only_handoff)

      expect(agent_tool_ids(assistant)).not_to include('create_appointment', 'update_appointment', 'cancel_appointment',
                                                       'get_my_contact', 'update_my_contact')
    end

    it 'takes the selected service catalog once' do
      account.enable_features!('scheduling')
      assistant.update!(config: { 'tool_access' => { 'agent' => { 'enabled' => true,
                                                                  'tool_ids' => %w[search_scheduling_services faq_lookup] } } })

      expect(agent_tool_ids(assistant).count('search_scheduling_services')).to eq(1)
      expect(agent_tool_ids(assistant).count('faq_lookup')).to eq(1)
    end

    it 'leaves out the service catalog of an account without the scheduling feature: it would only fail' do
      assistant.update!(config: only_handoff)

      expect(agent_tool_ids(assistant)).to include('faq_lookup')
      expect(agent_tool_ids(assistant)).not_to include('search_scheduling_services')
    end

    it 'leaves out the FAQ lookup where the platform has the FAQ off for the agent' do
      account.enable_features!('scheduling')
      assistant.update!(config: only_handoff)
      allow(assistant).to receive(:faq_enabled?).and_return(false)

      expect(described_class.shared_read_tool_ids_for(assistant, assistant.available_tool_ids)).to eq(['search_scheduling_services'])
    end

    it 'gives nothing to a tool that is not in the catalog of the agent' do
      account.enable_features!('scheduling')

      expect(described_class.shared_read_tool_ids_for(assistant, ['faq_lookup'])).to eq(['faq_lookup'])
      expect(described_class.shared_read_tool_ids_for(assistant, [])).to eq([])
    end

    it 'does not reach an agent that does not talk to customers' do
      account.enable_features!('scheduling')
      assistant.update!(config: only_handoff)
      allow(assistant).to receive(:external_agent?).and_return(false)

      expect(agent_tool_ids(assistant)).to eq(['handoff'])
    end
  end

  describe '.per_assistant_web_tool_enabled?' do
    it 'uses the account default when no per-agent permission fields are stored' do
      assistant.config = {}

      expect(described_class.per_assistant_web_tool_enabled?(assistant, 'web_search')).to be(false)
      expect(described_class.per_assistant_web_tool_enabled?(assistant, 'web_scrape_url')).to be(false)
    end

    it 'ignores the legacy aggregate flag when the account enables web access' do
      assistant.config = { 'feature_web' => false }
      assistant.account_settings.update!('understanding' => { 'web_search' => true, 'web_page_reading' => true })

      expect(described_class.per_assistant_web_tool_enabled?(assistant, 'web_search')).to be(true)
      expect(described_class.per_assistant_web_tool_enabled?(assistant, 'web_scrape_url')).to be(true)
    end

    it 'uses separate account web permissions when an agent scope is configured' do
      assistant.config = {
        'feature_web' => false,
        'tool_access' => {
          'agent' => { 'enabled' => true, 'tool_ids' => ['web_search'] }
        }
      }
      assistant.account_settings.update!('understanding' => { 'web_search' => true, 'web_page_reading' => false })

      expect(described_class.per_assistant_web_tool_enabled?(assistant, 'web_search')).to be(true)
      expect(described_class.per_assistant_web_tool_enabled?(assistant, 'web_scrape_url')).to be(false)
    end
  end
end
