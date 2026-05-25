# frozen_string_literal: true

# rubocop:disable RSpec/DescribeClass
require 'rails_helper'

RSpec.describe 'Captain automation rule copilot tools' do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:admin) { create(:user, :administrator, account: account) }
  let(:copilot_thread) { create(:captain_copilot_thread, account: account, user: admin, assistant: assistant) }

  let(:conditions) do
    [
      {
        attribute_key: 'status',
        filter_operator: 'equal_to',
        values: ['open'],
        query_operator: nil
      }
    ]
  end

  let(:actions) do
    [
      {
        action_name: 'add_label',
        action_params: ['priority_customer']
      }
    ]
  end

  before do
    confirmation_gate = instance_double(Captain::Copilot::ToolConfirmationGate, call: nil)
    allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_return(confirmation_gate)
  end

  def create_rule(name: 'VIP rule', active: true, rule_account: account)
    create(
      :automation_rule,
      account: rule_account,
      name: name,
      event_name: 'conversation_created',
      active: active,
      conditions: conditions.as_json,
      actions: actions.as_json
    )
  end

  describe Captain::Tools::Copilot::ListAutomationRulesService do
    let(:service) { described_class.new(assistant, user: admin) }

    it 'lists only account-scoped automation rules and supported events' do
      rule = create_rule(name: 'VIP open rule')
      create_rule(name: 'Other account rule', rule_account: create(:account))

      payload = JSON.parse(service.execute(query: 'vip', include_config: true))

      expect(payload['action']).to eq('list_automation_rules')
      expect(payload['total_count']).to eq(1)
      expect(payload['supported_event_names']).to include('conversation_created')
      expect(payload['rules']).to contain_exactly(include('id' => rule.id, 'name' => 'VIP open rule', 'event_name' => 'conversation_created'))
      expect(payload['rules'].first['conditions']).to be_present
      expect(payload['rules'].first['actions']).to be_present
    end
  end

  describe Captain::Tools::Copilot::GetAutomationRuleService do
    let(:service) { described_class.new(assistant, user: admin) }

    it 'returns one account rule with redacted configuration and catalogs' do
      rule = create_rule
      rule.update!(actions: [{ action_name: 'send_webhook_event', action_params: ['https://secret.example/webhook?token=abc'] }])

      payload = JSON.parse(service.execute(automation_rule_id: rule.id))

      expect(payload['action']).to eq('get_automation_rule')
      expect(payload['rule']).to include('id' => rule.id, 'name' => 'VIP rule')
      expect(payload.dig('rule', 'actions', 0, 'action_params')).to eq('[REDACTED]')
      expect(payload['supported_conditions']).to include('status')
      expect(payload['supported_actions']).to include('add_label')
    end

    it 'rejects rules outside the assistant account' do
      other_rule = create_rule(rule_account: create(:account))

      result = service.execute(automation_rule_id: other_rule.id)

      expect(result).to start_with('ERROR: ActiveRecord::RecordNotFound')
    end
  end

  describe Captain::Tools::Copilot::CreateAutomationRuleService do
    let(:service) { described_class.new(assistant, user: admin) }

    it 'creates a valid account automation rule' do
      payload = JSON.parse(
        service.execute(
          name: 'Auto tag open conversations',
          event_name: 'conversation_created',
          conditions_json: conditions.to_json,
          actions_json: actions.to_json,
          active: true
        )
      )

      rule = account.automation_rules.find(payload.dig('rule', 'id'))
      expect(payload['action']).to eq('create_automation_rule')
      expect(rule).to have_attributes(name: 'Auto tag open conversations', event_name: 'conversation_created', active: true)
      expect(rule.actions.first['action_name']).to eq('add_label')
    end

    it 'does not mutate until the backend confirmation gate permits execution' do
      allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_call_original

      payload = JSON.parse(service.execute(name: 'Needs approval', event_name: 'conversation_created', actions_json: actions.to_json))

      expect(payload['message']).to include('Operator confirmation is required')
      expect(account.automation_rules.find_by(name: 'Needs approval')).to be_nil
    end
  end

  describe Captain::Tools::Copilot::UpdateAutomationRuleService do
    let(:service) { described_class.new(assistant, user: admin) }

    it 'updates account automation rule fields and JSON configuration' do
      rule = create_rule(active: false)
      new_actions = [{ action_name: 'add_private_note', action_params: ['Escalate this conversation'] }]

      payload = JSON.parse(service.execute(automation_rule_id: rule.id, name: 'Updated rule', actions_json: new_actions.to_json, active: true))

      expect(payload['action']).to eq('update_automation_rule')
      expect(rule.reload).to have_attributes(name: 'Updated rule', active: true)
      expect(rule.actions.first['action_name']).to eq('add_private_note')
    end

    it 'rejects invalid JSON without mutating' do
      rule = create_rule

      result = service.execute(automation_rule_id: rule.id, actions_json: '{bad')

      expect(result).to include('actions_json must be valid JSON')
      expect(rule.reload.actions.first['action_name']).to eq('add_label')
    end
  end

  describe Captain::Tools::Copilot::SetAutomationRuleStatusService do
    let(:service) { described_class.new(assistant, user: admin) }

    it 'pauses and resumes account automation rules' do
      rule = create_rule(active: true)

      payload = JSON.parse(service.execute(automation_rule_id: rule.id, active: false))

      expect(payload['action']).to eq('set_automation_rule_status')
      expect(rule.reload.active).to be(false)
    end
  end

  describe Captain::Tools::Copilot::DeleteAutomationRuleService do
    let(:service) { described_class.new(assistant, user: admin) }

    it 'deletes an account automation rule' do
      rule = create_rule

      payload = JSON.parse(service.execute(automation_rule_id: rule.id))

      expect(payload['action']).to eq('delete_automation_rule')
      expect(payload['deleted']).to be(true)
      expect(account.automation_rules.exists?(rule.id)).to be(false)
    end
  end

  describe 'permissions and registry exposure' do
    it 'hides automation control tools from non-admin operators and rejects direct execution' do
      agent = create(:user, account: account)
      service = Captain::Tools::Copilot::CreateAutomationRuleService.new(assistant, user: agent)

      expect(service.active?).to be(false)
      result = service.execute(name: 'Unauthorized rule', event_name: 'conversation_created')

      expect(result).to include('Account administrator permission is required')
      expect(account.automation_rules.find_by(name: 'Unauthorized rule')).to be_nil
    end

    it 'does not create confirmation requests for inactive direct tool execution' do
      allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_call_original
      agent = create(:user, account: account)
      service = Captain::Tools::Copilot::CreateAutomationRuleService.new(assistant, user: agent, copilot_thread: copilot_thread)

      result = service.execute(name: 'Unauthorized rule', event_name: 'conversation_created')

      expect(result).to include('Account administrator permission is required')
      expect(copilot_thread.copilot_messages.assistant_thinking).to be_empty
      expect(account.automation_rules.find_by(name: 'Unauthorized rule')).to be_nil
    end

    it 'registers read tools as assistant-only low-risk tools' do
      read_tool_ids = %w[list_automation_rules get_automation_rule]

      read_tool_ids.each do |tool_id|
        definition = Captain::ToolRegistry.definition_for(tool_id)
        expect(definition.allowed_scopes).to eq([Captain::ToolAccess::SCOPE_ASSISTANT])
        expect(definition.idempotent).to be(true)
        expect(definition.risk_level).to eq('low')
      end

      expect(Captain::ToolRegistry.tools_for_scope(Captain::ToolAccess::SCOPE_AGENT).pluck(:id)).not_to include(*read_tool_ids)
    end

    it 'registers write tools as assistant-only high-risk confirmation tools' do
      write_tool_ids = %w[create_automation_rule update_automation_rule set_automation_rule_status delete_automation_rule]

      write_tool_ids.each do |tool_id|
        definition = Captain::ToolRegistry.definition_for(tool_id)
        expect(definition.allowed_scopes).to eq([Captain::ToolAccess::SCOPE_ASSISTANT])
        expect(definition.requires_confirmation).to be(true)
        expect(definition.risk_level).to eq('high')
        expect(definition.to_h[:selected_by_default]).to be(false)
      end

      expect(Captain::ToolRegistry.tools_for_scope(Captain::ToolAccess::SCOPE_AGENT).pluck(:id)).not_to include(*write_tool_ids)
    end
  end
end
# rubocop:enable RSpec/DescribeClass
