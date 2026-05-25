# frozen_string_literal: true

# rubocop:disable RSpec/DescribeClass
require 'rails_helper'

RSpec.describe 'Captain scenario admin copilot tools' do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account, name: 'Main Bot') }
  let(:scenario) do
    create(
      :captain_scenario,
      account: account,
      assistant: assistant,
      title: 'Billing Escalation',
      description: 'Handle billing escalations',
      instruction: 'Collect context before escalating.'
    )
  end
  let(:admin) { create(:user, :administrator, account: account) }

  before do
    confirmation_gate = instance_double(Captain::Copilot::ToolConfirmationGate, call: nil)
    allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_return(confirmation_gate)
  end

  describe Captain::Tools::Copilot::ListCaptainScenariosService do
    let(:service) { described_class.new(assistant, user: admin) }

    it 'lists account-scoped scenarios with assistant metadata' do
      scenario
      create(:captain_scenario, account: account, assistant: assistant, title: 'Disabled Flow', enabled: false)
      create(:captain_scenario, account: create(:account), title: 'Other Account')

      payload = JSON.parse(service.execute)

      expect(payload['action']).to eq('list_captain_scenarios')
      expect(payload['scenarios'].pluck('title')).to include('Billing Escalation', 'Disabled Flow')
      expect(payload['scenarios'].pluck('title')).not_to include('Other Account')
      expect(payload['scenarios'].first).to include('id', 'assistant_id', 'assistant_name', 'handoff_key', 'tool_ids')
    end

    it 'filters by assistant and enabled status' do
      scenario
      other_assistant = create(:captain_assistant, account: account)
      create(:captain_scenario, account: account, assistant: other_assistant, title: 'Other Assistant')
      create(:captain_scenario, account: account, assistant: assistant, title: 'Disabled Flow', enabled: false)

      payload = JSON.parse(service.execute(assistant_id: assistant.id, enabled: true))

      expect(payload['scenarios'].pluck('title')).to eq(['Billing Escalation'])
    end

    it 'rejects direct non-admin execution as defense in depth' do
      agent = create(:user, account: account)

      result = described_class.new(assistant, user: agent).execute

      expect(result).to include('Account administrator permission is required')
    end
  end

  describe Captain::Tools::Copilot::GetCaptainScenarioService do
    let(:service) { described_class.new(assistant, user: admin) }

    it 'returns one scenario with redacted instruction content' do
      scenario.update!(instruction: 'Use session=abc, password: p4ss, authorization: Basic aaa and webhook_secret=xyz')

      payload = JSON.parse(service.execute(scenario_id: scenario.id))
      serialized_payload = JSON.generate(payload)

      expect(payload['action']).to eq('get_captain_scenario')
      expect(payload['scenario']).to include('id' => scenario.id, 'instruction' => '[FILTERED]')
      expect(serialized_payload).not_to include('session=abc')
      expect(serialized_payload).not_to include('password: p4ss')
      expect(serialized_payload).not_to include('authorization: Basic aaa')
      expect(serialized_payload).not_to include('webhook_secret=xyz')
    end

    it 'rejects cross-account scenarios' do
      other_scenario = create(:captain_scenario, account: create(:account))

      result = service.execute(scenario_id: other_scenario.id)

      expect(result).to start_with('ERROR: ActiveRecord::RecordNotFound')
    end
  end

  describe Captain::Tools::Copilot::CreateCaptainScenarioService do
    let(:service) { described_class.new(assistant, user: admin) }

    it 'creates a scenario and materializes managed tool references' do
      payload = JSON.parse(
        service.execute(
          assistant_id: assistant.id,
          title: 'VIP Refunds',
          description: 'Handle VIP refund requests',
          instruction: 'Collect order details.',
          tool_ids_json: ['handoff'].to_json
        )
      )

      created_scenario = Captain::Scenario.where(account: account).find(payload['scenario']['id'])
      expect(payload['action']).to eq('create_captain_scenario')
      expect(payload['scenario']['tool_ids']).to eq(['handoff'])
      expect(created_scenario.instruction).to include('Scenario tool references: [Handoff to Human](tool://handoff)')
      expect(created_scenario.tools).to eq(['handoff'])
    end

    it 'does not mutate until the backend confirmation gate permits execution' do
      allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_call_original

      payload = JSON.parse(
        service.execute(
          assistant_id: assistant.id,
          title: 'Needs Approval',
          description: 'Pending confirmation',
          instruction: 'Do not create yet.'
        )
      )

      expect(payload['message']).to include('Operator confirmation is required')
      expect(Captain::Scenario.where(account: account).where(title: 'Needs Approval')).not_to exist
    end

    it 'rejects invalid tool IDs without mutation' do
      result = service.execute(
        assistant_id: assistant.id,
        title: 'Broken',
        description: 'Invalid tools',
        instruction: 'Try invalid tool.',
        tool_ids_json: ['missing_tool'].to_json
      )

      expect(result).to include('tool_ids_json contains invalid tools: missing_tool')
      expect(Captain::Scenario.where(account: account).where(title: 'Broken')).not_to exist
    end

    it 'rejects unmanaged inline tool references in instructions' do
      result = service.execute(
        assistant_id: assistant.id,
        title: 'Smuggled Tool',
        description: 'Should not create',
        instruction: 'Call [Handoff](tool://handoff) outside the managed tool list.'
      )

      expect(result).to include('Use tool_ids_json to manage scenario tool references')
      expect(Captain::Scenario.where(account: account).where(title: 'Smuggled Tool')).not_to exist
    end

    it 'rejects caller-supplied managed-looking and plain tool references without tool_ids_json' do
      result = service.execute(
        assistant_id: assistant.id,
        title: 'Managed Smuggle',
        description: 'Should not create',
        instruction: "Scenario tool references: [Handoff](tool://handoff)\nAlso call tool://cancel_response"
      )

      expect(result).to include('Use tool_ids_json to manage scenario tool references')
      expect(Captain::Scenario.where(account: account).where(title: 'Managed Smuggle')).not_to exist
    end
  end

  describe Captain::Tools::Copilot::UpdateCaptainScenarioService do
    let(:service) { described_class.new(assistant, user: admin) }

    it 'updates scenario fields and returns rollback-safe previous payload' do
      payload = JSON.parse(
        service.execute(
          scenario_id: scenario.id,
          title: 'Updated Billing Escalation',
          tool_ids_json: ['handoff'].to_json
        )
      )

      expect(payload['action']).to eq('update_captain_scenario')
      expect(payload['previous_scenario']).to include('title' => 'Billing Escalation')
      expect(payload['updated_fields']).to contain_exactly('title', 'instruction')
      expect(payload['scenario']['tool_ids']).to eq(['handoff'])
      expect(scenario.reload).to have_attributes(title: 'Updated Billing Escalation', tools: ['handoff'])
    end

    it 'does not mutate until the backend confirmation gate permits execution' do
      allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_call_original

      payload = JSON.parse(service.execute(scenario_id: scenario.id, title: 'Needs Approval'))

      expect(payload['message']).to include('Operator confirmation is required')
      expect(scenario.reload.title).to eq('Billing Escalation')
    end

    it 'rejects direct non-admin execution as defense in depth' do
      agent = create(:user, account: account)

      result = described_class.new(assistant, user: agent).execute(scenario_id: scenario.id, title: 'Unauthorized')

      expect(result).to include('Account administrator permission is required')
      expect(scenario.reload.title).to eq('Billing Escalation')
    end

    it 'rejects unmanaged inline tool references on instruction updates' do
      result = service.execute(
        scenario_id: scenario.id,
        instruction: 'Try to call [Handoff](tool://handoff) without tool_ids_json.'
      )

      expect(result).to include('Use tool_ids_json to manage scenario tool references')
      expect(scenario.reload.tools).to be_blank
      expect(scenario.instruction).to eq('Collect context before escalating.')
    end

    it 'removes old managed blocks and applies tool_ids_json as the authoritative tool list' do
      scenario.update!(instruction: "Keep this.\n\nScenario tool references: [Cancel Response](tool://cancel_response)")

      payload = JSON.parse(service.execute(scenario_id: scenario.id, tool_ids_json: ['handoff'].to_json))

      expect(payload['scenario']['tool_ids']).to eq(['handoff'])
      expect(scenario.reload.instruction).to include('Scenario tool references: [Handoff to Human](tool://handoff)')
      expect(scenario.instruction).not_to include('cancel_response')
    end
  end

  describe Captain::Tools::Copilot::SetCaptainScenarioStatusService do
    let(:service) { described_class.new(assistant, user: admin) }

    it 'enables or disables a scenario' do
      payload = JSON.parse(service.execute(scenario_id: scenario.id, enabled: false))

      expect(payload['action']).to eq('set_captain_scenario_status')
      expect(payload['scenario']['enabled']).to be(false)
      expect(scenario.reload.enabled).to be(false)
    end
  end

  describe Captain::Tools::Copilot::DeleteCaptainScenarioService do
    let(:service) { described_class.new(assistant, user: admin) }

    it 'deletes a scenario and returns a redacted rollback payload' do
      scenario.update!(instruction: 'Use secret=abc before deleting')

      payload = JSON.parse(service.execute(scenario_id: scenario.id))
      serialized_payload = JSON.generate(payload)

      expect(payload['action']).to eq('delete_captain_scenario')
      expect(payload['deleted_scenario']).to include('id' => scenario.id, 'instruction' => '[FILTERED]')
      expect(serialized_payload).not_to include('secret=abc')
      expect(Captain::Scenario.where(account: account).where(id: scenario.id)).not_to exist
    end
  end

  describe 'registry exposure' do
    it 'registers scenario admin tools as assistant-only with confirmation for writes', :aggregate_failures do
      read_tool_ids = %w[list_captain_scenarios get_captain_scenario]
      write_tool_ids = %w[create_captain_scenario update_captain_scenario set_captain_scenario_status delete_captain_scenario]

      read_tool_ids.each do |tool_id|
        definition = Captain::ToolRegistry.definition_for(tool_id)
        expect(definition.allowed_scopes).to eq([Captain::ToolAccess::SCOPE_ASSISTANT])
        expect(definition.requires_confirmation).not_to be(true)
        expect(definition.risk_level).to eq('low')
      end

      write_tool_ids.each do |tool_id|
        definition = Captain::ToolRegistry.definition_for(tool_id)
        expect(definition.allowed_scopes).to eq([Captain::ToolAccess::SCOPE_ASSISTANT])
        expect(definition.requires_confirmation).to be(true)
        expect(definition.risk_level).to eq('high')
        expect(definition.to_h[:selected_by_default]).to be(false)
      end

      expect(Captain::ToolRegistry.tools_for_scope(Captain::ToolAccess::SCOPE_AGENT).pluck(:id)).not_to include(*(read_tool_ids + write_tool_ids))
      expect(Captain::ToolRegistry.tools_for_scope(Captain::ToolAccess::SCOPE_ASSISTANT).pluck(:id)).to include(*(read_tool_ids + write_tool_ids))
    end
  end
end
# rubocop:enable RSpec/DescribeClass
