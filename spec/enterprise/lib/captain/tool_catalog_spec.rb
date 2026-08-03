require 'rails_helper'

RSpec.describe Captain::ToolCatalog do
  let(:account) do
    create(:account).tap do |account|
      account.enable_features!('crm_deals', 'crm_tasks', 'scheduling', 'scheduling_finance')
    end
  end
  let(:assistant) { create(:captain_assistant, account: account) }

  describe '.available_tools_for' do
    it 'uses the registry as the built-in source of truth for agent tools' do
      tool_ids = described_class.available_tools_for(assistant, Captain::ToolAccess::SCOPE_AGENT).pluck(:id)

      expect(tool_ids).to include('faq_lookup', 'handoff', 'create_deal')
    end

    it 'marks high-risk built-in assistant tools as confirmation-required without changing agent scope' do
      assistant_create_deal = described_class
                              .available_tools_for(assistant, Captain::ToolAccess::SCOPE_ASSISTANT)
                              .find { |tool| tool[:id] == 'create_deal' }
      agent_create_deal = described_class
                          .available_tools_for(assistant, Captain::ToolAccess::SCOPE_AGENT)
                          .find { |tool| tool[:id] == 'create_deal' }

      expect(assistant_create_deal[:risk_level]).to eq('high')
      expect(assistant_create_deal[:requires_confirmation]).to be(true)
      expect(agent_create_deal[:requires_confirmation]).to be_falsey
    end

    it 'keeps account-admin inbox tools assistant-only and confirms auto-reply changes' do
      assistant_tools = described_class.available_tools_for(assistant, Captain::ToolAccess::SCOPE_ASSISTANT)
      agent_tool_ids = described_class.available_tools_for(assistant, Captain::ToolAccess::SCOPE_AGENT).pluck(:id)

      expect(assistant_tools.find { |tool| tool[:id] == 'list_inboxes' }).to include(risk_level: 'low')
      expect(assistant_tools.find { |tool| tool[:id] == 'list_assignment_policies' }).to include(risk_level: 'low')
      expect(assistant_tools.find { |tool| tool[:id] == 'get_inbox_settings' }).to include(risk_level: 'low')
      %w[
        set_inbox_assignment_policy
        update_inbox_settings
        update_inbox_working_hours
        add_inbox_members
        remove_inbox_members
        update_captain_inbox_auto_reply_mode
      ].each do |tool_id|
        expect(assistant_tools.find { |tool| tool[:id] == tool_id }).to include(
          risk_level: 'high',
          requires_confirmation: true
        )
      end
      expect(agent_tool_ids).not_to include(
        'list_inboxes',
        'list_assignment_policies',
        'get_inbox_settings',
        'set_inbox_assignment_policy',
        'update_inbox_settings',
        'update_inbox_working_hours',
        'add_inbox_members',
        'remove_inbox_members',
        'update_captain_inbox_auto_reply_mode'
      )
    end

    it 'marks account-admin label mutations as confirmation-required assistant tools' do
      assistant_tools = described_class.available_tools_for(assistant, Captain::ToolAccess::SCOPE_ASSISTANT)

      %w[create_label update_label].each do |tool_id|
        expect(assistant_tools.find { |tool| tool[:id] == tool_id }).to include(
          requires_confirmation: true
        )
      end
    end

    it 'keeps employee-actor and private conversation tools out of the customer-agent scope' do
      assistant_tool_ids = described_class.available_tools_for(assistant, Captain::ToolAccess::SCOPE_ASSISTANT).pluck(:id)
      agent_tool_ids = described_class.available_tools_for(assistant, Captain::ToolAccess::SCOPE_AGENT).pluck(:id)
      restricted_tool_ids = %w[add_deal_comment add_task_comment get_conversation]

      expect(assistant_tool_ids).to include(*restricted_tool_ids)
      expect(agent_tool_ids).not_to include(*restricted_tool_ids)
    end

    it 'keeps Kaspi Pay provider reads assistant-only and confirms invoice cancellation' do
      create(:integrations_hook, :kaspi_pay, account: account)

      assistant_tools = described_class.available_tools_for(assistant, Captain::ToolAccess::SCOPE_ASSISTANT)
      agent_tool_ids = described_class.available_tools_for(assistant, Captain::ToolAccess::SCOPE_AGENT).pluck(:id)

      %w[get_kaspi_pay_client_info get_kaspi_pay_provider_history].each do |tool_id|
        expect(assistant_tools.find { |tool| tool[:id] == tool_id }).to include(risk_level: 'low')
      end
      expect(assistant_tools.find { |tool| tool[:id] == 'get_kaspi_pay_integration_status' }).to include(
        risk_level: 'medium',
        requires_confirmation: true
      )
      expect(assistant_tools.find { |tool| tool[:id] == 'cancel_kaspi_pay_invoice' }).to include(
        risk_level: 'high',
        requires_confirmation: true
      )
      expect(agent_tool_ids).not_to include(
        'get_kaspi_pay_client_info',
        'get_kaspi_pay_provider_history',
        'cancel_kaspi_pay_invoice'
      )
    end

    it 'includes enabled custom tools for the requested scope' do
      custom_tool = create(:captain_custom_tool, account: account)

      agent_tool_ids = described_class.available_tools_for(assistant, Captain::ToolAccess::SCOPE_AGENT).pluck(:id)
      assistant_tool_ids = described_class.available_tools_for(assistant, Captain::ToolAccess::SCOPE_ASSISTANT).pluck(:id)

      expect(agent_tool_ids).to include(custom_tool.slug)
      expect(assistant_tool_ids).to include(custom_tool.slug)
      expect(
        described_class.available_tools_for(assistant, Captain::ToolAccess::SCOPE_ASSISTANT)
                       .find { |tool| tool[:id] == custom_tool.slug }[:requires_confirmation]
      ).to be(true)
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

    it 'hides Kaspi Pay payment tools until this account has an enabled Kaspi Pay integration' do
      create(:integrations_hook, :kaspi_pay, account: create(:account))
      create(:integrations_hook, :kaspi_pay, account: account, status: 'disabled')

      agent_tool_ids = described_class.available_tools_for(assistant, Captain::ToolAccess::SCOPE_AGENT).pluck(:id)
      assistant_tool_ids = described_class.available_tools_for(assistant, Captain::ToolAccess::SCOPE_ASSISTANT).pluck(:id)

      expect(agent_tool_ids).not_to include(*kaspi_pay_agent_payment_tool_ids)
      expect(assistant_tool_ids).not_to include(*kaspi_pay_connected_tool_ids)
      expect(assistant_tool_ids).to include(
        'get_kaspi_pay_integration_status',
        'start_kaspi_pay_connection',
        'send_kaspi_pay_phone',
        'verify_kaspi_pay_otp'
      )
    end

    it 'exposes Kaspi Pay payment tools only for the account with an enabled Kaspi Pay integration' do
      other_account = create(:account)
      other_assistant = create(:captain_assistant, account: other_account)
      create(:integrations_hook, :kaspi_pay, account: account)

      agent_tool_ids = described_class.available_tools_for(assistant, Captain::ToolAccess::SCOPE_AGENT).pluck(:id)
      assistant_tool_ids = described_class.available_tools_for(assistant, Captain::ToolAccess::SCOPE_ASSISTANT).pluck(:id)
      other_assistant_tool_ids = described_class.available_tools_for(other_assistant, Captain::ToolAccess::SCOPE_ASSISTANT).pluck(:id)

      expect(agent_tool_ids).to include(*kaspi_pay_agent_payment_tool_ids)
      expect(assistant_tool_ids).to include(*kaspi_pay_connected_tool_ids)
      expect(other_assistant_tool_ids).not_to include(*kaspi_pay_connected_tool_ids)
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

    it 'keeps built-in tools available when MCP discovery fails' do
      create(:captain_mcp_server, account: account)
      allow(Captain::Mcp::ToolCatalog::DiscoveryService).to receive(:new).and_raise(
        NameError,
        'broken MCP discovery'
      )

      tool_ids = described_class.available_tools_for(assistant, Captain::ToolAccess::SCOPE_AGENT).pluck(:id)

      expect(tool_ids).to include('faq_lookup', 'handoff', 'create_deal')
    end

    it 'normalizes first-class source types across system, custom, MCP, and skill tools' do
      custom_tool = create(:captain_custom_tool, account: account)
      allow(Captain::Mcp::ToolCatalog).to receive(:available_tools_for)
        .and_return([
                      {
                        id: 'mcp__github_mcp__list_issues',
                        title: 'List issues',
                        description: 'List repository issues',
                        provider: 'mcp'
                      }
                    ])
      allow(Captain::SkillCatalog).to receive(:script_tools_for)
        .and_return([
                      {
                        id: 'skill_script_support_summary',
                        title: 'Support summary',
                        description: 'Summarize support context',
                        provider: 'skill_script'
                      }
                    ])

      tools = described_class.available_tools_for(assistant, Captain::ToolAccess::SCOPE_AGENT)

      expect(tools.find { |tool| tool[:id] == 'faq_lookup' }).to include(source_type: 'system')
      expect(tools.find { |tool| tool[:id] == custom_tool.slug }).to include(source_type: 'custom')
      expect(tools.find { |tool| tool[:id] == 'mcp__github_mcp__list_issues' }).to include(source_type: 'mcp')
      expect(tools.find { |tool| tool[:id] == 'skill_script_support_summary' }).to include(source_type: 'skill')
    end

    it 'marks non-idempotent assistant MCP tools as confirmation-required' do
      allow(Captain::Mcp::ToolCatalog).to receive(:available_tools_for)
        .with(assistant, Captain::ToolAccess::SCOPE_ASSISTANT)
        .and_return([
                      {
                        id: 'mcp__github_mcp__delete_issue',
                        title: 'Delete issue',
                        description: 'Delete repository issue',
                        provider: 'mcp',
                        risk_level: 'high',
                        idempotent: false,
                        mcp_server_id: 123,
                        mcp_tool_name: 'delete_issue'
                      }
                    ])

      tool = described_class.available_tools_for(assistant, Captain::ToolAccess::SCOPE_ASSISTANT)
                            .find { |definition| definition[:id] == 'mcp__github_mcp__delete_issue' }

      expect(tool[:requires_confirmation]).to be(true)
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

  describe '.available_tools_for_ids' do
    it 'resolves a built-in tool without scanning the full registry or discovering MCP tools' do
      expect(Captain::ToolRegistry).not_to receive(:tools_for_scope)
      expect(Captain::Mcp::ToolCatalog).not_to receive(:available_tools_for)

      tools = described_class.available_tools_for_ids(
        assistant,
        Captain::ToolAccess::SCOPE_AGENT,
        ['faq_lookup']
      )

      expect(tools).to contain_exactly(include(id: 'faq_lookup', source_type: 'system'))
    end

    it 'resolves account-scoped custom tools without relying on a slug prefix' do
      custom_tool = create(:captain_custom_tool, account: account, slug: 'workspace_status_lookup')

      tools = described_class.available_tools_for_ids(
        assistant,
        Captain::ToolAccess::SCOPE_AGENT,
        [custom_tool.slug]
      )

      expect(tools).to contain_exactly(include(id: custom_tool.slug, source_type: 'custom'))
    end

    it 'resolves skill tools without relying on a tool id prefix' do
      allow(Captain::SkillCatalog).to receive(:script_tools_for).and_return(
        [
          {
            id: 'workspace_status_script',
            title: 'Workspace status',
            description: 'Read workspace status',
            provider: 'skill_script'
          }
        ]
      )
      expect(Captain::Mcp::ToolCatalog).not_to receive(:available_tools_for)

      tools = described_class.available_tools_for_ids(
        assistant,
        Captain::ToolAccess::SCOPE_AGENT,
        ['workspace_status_script']
      )

      expect(tools).to contain_exactly(include(id: 'workspace_status_script', source_type: 'skill'))
    end

    it 'discovers MCP only for unresolved MCP ids and ignores stale ids' do
      allow(Captain::Mcp::ToolCatalog).to receive(:available_tools_for)
        .with(assistant, Captain::ToolAccess::SCOPE_AGENT)
        .and_return([
                      {
                        id: 'mcp__github_mcp__list_issues',
                        title: 'List issues',
                        description: 'List repository issues',
                        provider: 'mcp'
                      }
                    ])

      tools = described_class.available_tools_for_ids(
        assistant,
        Captain::ToolAccess::SCOPE_AGENT,
        %w[mcp__github_mcp__list_issues stale_tool_id]
      )

      expect(tools).to contain_exactly(include(id: 'mcp__github_mcp__list_issues', source_type: 'mcp'))
      expect(Captain::Mcp::ToolCatalog).to have_received(:available_tools_for).once
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

    it 'builds delegated account tools for the customer-facing agent scope' do
      tool = described_class.build_tool(
        { id: 'search_available_slots', custom: false },
        assistant: assistant,
        scope_name: Captain::ToolAccess::SCOPE_AGENT
      )

      expect(tool).to be_a(Captain::Tools::Agent::AccountToolAdapter)
      expect(tool.name).to eq('search_available_slots')
      expect(tool.description).to include('Search appointment slots')
      expect(tool.parameters.keys.map(&:to_s)).to include('from', 'to')
    end

    it 'builds delegated high-risk agent tools once the agent catalog exposes them' do
      tool = described_class.build_tool(
        Captain::ToolRegistry.definition_for('create_deal').to_h,
        assistant: assistant,
        scope_name: Captain::ToolAccess::SCOPE_AGENT
      )

      expect(tool).to be_a(Captain::Tools::CreateDealTool)
      expect(tool.name).to eq('create_deal')
    end

    it 'builds every built-in customer-facing agent tool with runnable metadata' do
      Captain::ToolRegistry.tools_for_scope(Captain::ToolAccess::SCOPE_AGENT).each do |tool_definition|
        tool = described_class.build_tool(
          tool_definition,
          assistant: assistant,
          scope_name: Captain::ToolAccess::SCOPE_AGENT
        )

        aggregate_failures(tool_definition[:id]) do
          expect(tool).to be_present
          expect(tool.name).to eq(tool_definition[:id])
          expect(tool.description).to be_present
          expect(tool.parameters).to be_a(Hash)
          expect(tool.params_schema).to be_present if tool.parameters.present?
          expect(tool).to be_active
        end
      end
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
    it 'formats tool summaries consistently and includes confirmation metadata when provided' do
      summary = described_class.summary_for(
        [
          { id: 'faq_lookup', description: 'Search FAQ responses' },
          { id: 'handoff', description: 'Hand off the conversation' },
          {
            id: 'send_message_to_conversation',
            description: 'Send a public reply',
            risk_level: 'high',
            requires_confirmation: true
          }
        ]
      )

      expect(summary).to eq(
        "- faq_lookup: Search FAQ responses\n" \
        "- handoff: Hand off the conversation\n" \
        '- send_message_to_conversation: Send a public reply (risk: high, requires operator confirmation)'
      )
    end
  end

  def kaspi_pay_agent_payment_tool_ids
    %w[
      create_kaspi_pay_payment
      get_kaspi_pay_payment_status
    ]
  end

  def kaspi_pay_connected_tool_ids
    kaspi_pay_agent_payment_tool_ids + %w[
      disconnect_kaspi_pay
      get_kaspi_pay_client_info
      get_kaspi_pay_provider_history
      search_kaspi_pay_payments
      get_kaspi_pay_payment
      sync_kaspi_pay_payment_status
      refund_kaspi_pay_payment
      cancel_kaspi_pay_invoice
      reconcile_kaspi_pay_payment
    ]
  end
end
