# frozen_string_literal: true

# rubocop:disable RSpec/DescribeClass
require 'rails_helper'

RSpec.describe 'Captain support content copilot tools' do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:admin) { create(:user, :administrator, account: account) }
  let(:copilot_thread) { create(:captain_copilot_thread, account: account, user: admin, assistant: assistant) }

  let(:macro_actions) do
    [
      {
        action_name: 'add_label',
        action_params: ['vip']
      }
    ]
  end

  before do
    confirmation_gate = instance_double(Captain::Copilot::ToolConfirmationGate, call: nil)
    allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_return(confirmation_gate)
  end

  describe Captain::Tools::Copilot::SearchCannedResponsesService do
    it 'keeps read access account-scoped' do
      response = create(:canned_response, account: account, short_code: 'shipping', content: 'Shipping response')
      create(:canned_response, account: create(:account), short_code: 'shipping-other', content: 'Other account response')

      payload = JSON.parse(described_class.new(assistant, user: admin).execute(query: 'ship'))

      expect(payload['total_count']).to eq(1)
      expect(payload['canned_responses']).to contain_exactly(include('id' => response.id, 'short_code' => 'shipping'))
    end
  end

  describe Captain::Tools::Copilot::GetCannedResponseService do
    it 'returns one account canned response and rejects cross-account IDs' do
      response = create(:canned_response, account: account, short_code: 'hello', content: 'Hello!')
      other = create(:canned_response, account: create(:account), short_code: 'other', content: 'Nope')
      service = described_class.new(assistant, user: admin)

      payload = JSON.parse(service.execute(canned_response_id: response.id))

      expect(payload['action']).to eq('get_canned_response')
      expect(payload.dig('canned_response', 'content')).to eq('Hello!')
      expect(service.execute(canned_response_id: other.id)).to start_with('ERROR: ActiveRecord::RecordNotFound')
    end

    it 'rejects non-admin direct execution' do
      response = create(:canned_response, account: account)
      agent = create(:user, account: account)

      result = described_class.new(assistant, user: agent).execute(canned_response_id: response.id)

      expect(result).to include('Account administrator permission is required')
    end
  end

  describe Captain::Tools::Copilot::CreateCannedResponseService do
    it 'creates a canned response only after backend confirmation permits execution' do
      allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_call_original
      service = described_class.new(assistant, user: admin, copilot_thread: copilot_thread)

      blocked = JSON.parse(service.execute(short_code: 'welcome', content: 'Welcome aboard'))

      expect(blocked['message']).to include('Operator confirmation is required')
      expect(account.canned_responses.find_by(short_code: 'welcome')).to be_nil
    end

    it 'creates a canned response when confirmation is satisfied' do
      service = described_class.new(assistant, user: admin)

      payload = JSON.parse(service.execute(short_code: 'welcome', content: 'Welcome aboard'))

      expect(payload['action']).to eq('create_canned_response')
      expect(payload.dig('canned_response', 'short_code')).to eq('welcome')
      expect(account.canned_responses.find_by(short_code: 'welcome')).to be_present
    end
  end

  describe Captain::Tools::Copilot::UpdateCannedResponseService do
    it 'updates account canned responses and rejects non-admin direct execution' do
      response = create(:canned_response, account: account, short_code: 'old', content: 'Old')
      service = described_class.new(assistant, user: admin)

      payload = JSON.parse(service.execute(canned_response_id: response.id, short_code: 'new', content: 'New'))

      expect(payload['action']).to eq('update_canned_response')
      expect(response.reload).to have_attributes(short_code: 'new', content: 'New')

      agent = create(:user, account: account)
      result = described_class.new(assistant, user: agent).execute(canned_response_id: response.id, content: 'Unauthorized')

      expect(result).to include('Account administrator permission is required')
      expect(response.reload.content).to eq('New')
    end

    it 'does not update without backend confirmation' do
      allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_call_original
      response = create(:canned_response, account: account, short_code: 'safe', content: 'Safe')
      service = described_class.new(assistant, user: admin, copilot_thread: copilot_thread)

      payload = JSON.parse(service.execute(canned_response_id: response.id, content: 'Unsafe without approval'))

      expect(payload['message']).to include('Operator confirmation is required')
      expect(response.reload.content).to eq('Safe')
    end
  end

  describe Captain::Tools::Copilot::DeleteCannedResponseService do
    it 'deletes only account-scoped canned responses' do
      response = create(:canned_response, account: account)
      other = create(:canned_response, account: create(:account))
      service = described_class.new(assistant, user: admin)

      payload = JSON.parse(service.execute(canned_response_id: response.id))

      expect(payload['action']).to eq('delete_canned_response')
      expect(payload['deleted']).to be(true)
      expect(account.canned_responses.exists?(response.id)).to be(false)
      expect(service.execute(canned_response_id: other.id)).to start_with('ERROR: ActiveRecord::RecordNotFound')
    end

    it 'does not delete without backend confirmation' do
      allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_call_original
      response = create(:canned_response, account: account)
      service = described_class.new(assistant, user: admin, copilot_thread: copilot_thread)

      payload = JSON.parse(service.execute(canned_response_id: response.id))

      expect(payload['message']).to include('Operator confirmation is required')
      expect(account.canned_responses.exists?(response.id)).to be(true)
    end
  end

  describe Captain::Tools::Copilot::ListMacrosService do
    it 'lists account macros with redacted sensitive action values' do
      macro = create(:macro, account: account, name: 'Webhook macro')
      webhook_url = 'https://secret.example/hook?token=secret'
      macro.update!(
        actions: [
          {
            action_name: 'send_webhook_event',
            action_params: [webhook_url]
          }
        ]
      )
      create(:macro, account: create(:account), name: 'Other account macro')

      payload = JSON.parse(described_class.new(assistant, user: admin).execute(query: 'Webhook', include_actions: true))

      expect(payload['action']).to eq('list_macros')
      expect(payload['total_count']).to eq(1)
      expect(payload['macros']).to contain_exactly(include('id' => macro.id, 'name' => 'Webhook macro'))
      expect(payload.dig('macros', 0, 'actions', 0, 'action_params')).to eq('[REDACTED]')
      expect(payload.to_json).not_to include('secret.example', 'token=secret')
    end

    it 'rejects non-admin direct execution' do
      create(:macro, account: account, name: 'Private macro')
      agent = create(:user, account: account)

      result = described_class.new(assistant, user: agent).execute

      expect(result).to include('Account administrator permission is required')
    end
  end

  describe Captain::Tools::Copilot::GetMacroService do
    it 'returns one account macro with supported action catalog' do
      macro = create(:macro, account: account, name: 'Support macro', actions: macro_actions.as_json)
      other = create(:macro, account: create(:account), name: 'Other macro')
      service = described_class.new(assistant, user: admin)

      payload = JSON.parse(service.execute(macro_id: macro.id))

      expect(payload['action']).to eq('get_macro')
      expect(payload['macro']).to include('id' => macro.id, 'name' => 'Support macro')
      expect(payload['supported_actions']).to include('add_label')
      expect(service.execute(macro_id: other.id)).to start_with('ERROR: ActiveRecord::RecordNotFound')
    end

    it 'rejects non-admin direct execution' do
      macro = create(:macro, account: account)
      agent = create(:user, account: account)

      result = described_class.new(assistant, user: agent).execute(macro_id: macro.id)

      expect(result).to include('Account administrator permission is required')
    end
  end

  describe Captain::Tools::Copilot::CreateMacroService do
    it 'creates a global account macro with validated actions JSON' do
      service = described_class.new(assistant, user: admin)

      payload = JSON.parse(service.execute(name: 'VIP tag', actions_json: macro_actions.to_json))
      macro = account.macros.find(payload.dig('macro', 'id'))

      expect(payload['action']).to eq('create_macro')
      expect(macro).to have_attributes(name: 'VIP tag', visibility: 'global', created_by_id: admin.id, updated_by_id: admin.id)
      expect(macro.actions.first['action_name']).to eq('add_label')
    end

    it 'does not mutate without confirmation when called from a copilot thread' do
      allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_call_original
      service = described_class.new(assistant, user: admin, copilot_thread: copilot_thread)

      payload = JSON.parse(service.execute(name: 'Needs approval', actions_json: macro_actions.to_json))

      expect(payload['message']).to include('Operator confirmation is required')
      expect(account.macros.find_by(name: 'Needs approval')).to be_nil
    end
  end

  describe Captain::Tools::Copilot::UpdateMacroService do
    it 'updates macro metadata/actions and rejects invalid JSON without mutation' do
      macro = create(:macro, account: account, name: 'Old macro', visibility: 'personal', actions: macro_actions.as_json)
      new_actions = [{ action_name: 'add_private_note', action_params: ['Escalate'] }]
      service = described_class.new(assistant, user: admin)

      payload = JSON.parse(service.execute(macro_id: macro.id, name: 'Updated macro', visibility: 'global', actions_json: new_actions.to_json))

      expect(payload['action']).to eq('update_macro')
      expect(macro.reload).to have_attributes(name: 'Updated macro', visibility: 'global', updated_by_id: admin.id)
      expect(macro.actions.first['action_name']).to eq('add_private_note')

      result = service.execute(macro_id: macro.id, actions_json: '{bad')
      expect(result).to include('actions_json must be valid JSON')
      expect(macro.reload.actions.first['action_name']).to eq('add_private_note')
    end

    it 'does not update without backend confirmation' do
      allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_call_original
      macro = create(:macro, account: account, name: 'Safe macro', actions: macro_actions.as_json)
      service = described_class.new(assistant, user: admin, copilot_thread: copilot_thread)

      payload = JSON.parse(service.execute(macro_id: macro.id, name: 'Unsafe without approval'))

      expect(payload['message']).to include('Operator confirmation is required')
      expect(macro.reload.name).to eq('Safe macro')
    end
  end

  describe Captain::Tools::Copilot::DeleteMacroService do
    it 'deletes account macros and rejects non-admin direct execution' do
      macro = create(:macro, account: account)
      service = described_class.new(assistant, user: admin)

      payload = JSON.parse(service.execute(macro_id: macro.id))

      expect(payload['action']).to eq('delete_macro')
      expect(payload['deleted']).to be(true)
      expect(account.macros.exists?(macro.id)).to be(false)

      agent = create(:user, account: account)
      other_macro = create(:macro, account: account)
      result = described_class.new(assistant, user: agent).execute(macro_id: other_macro.id)
      expect(result).to include('Account administrator permission is required')
      expect(account.macros.exists?(other_macro.id)).to be(true)
    end

    it 'does not delete without backend confirmation' do
      allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_call_original
      macro = create(:macro, account: account)
      service = described_class.new(assistant, user: admin, copilot_thread: copilot_thread)

      payload = JSON.parse(service.execute(macro_id: macro.id))

      expect(payload['message']).to include('Operator confirmation is required')
      expect(account.macros.exists?(macro.id)).to be(true)
    end
  end

  describe 'registry exposure and safety metadata' do
    it 'keeps write support-content tools assistant-only with high risk confirmation' do
      write_tool_ids = %w[
        create_canned_response update_canned_response delete_canned_response
        create_macro update_macro delete_macro
      ]

      write_tool_ids.each do |tool_id|
        definition = Captain::ToolRegistry.definition_for(tool_id)
        expect(definition.allowed_scopes).to eq([Captain::ToolAccess::SCOPE_ASSISTANT])
        expect(definition.requires_confirmation).to be(true)
        expect(definition.risk_level).to eq('high')
        expect(definition.to_h[:selected_by_default]).to be(false)
      end

      expect(Captain::ToolRegistry.tools_for_scope(Captain::ToolAccess::SCOPE_AGENT).pluck(:id)).not_to include(*write_tool_ids)
    end

    it 'keeps read macro/support tools assistant-only except safe search_canned_responses' do
      read_tool_ids = %w[get_canned_response list_macros get_macro]

      read_tool_ids.each do |tool_id|
        definition = Captain::ToolRegistry.definition_for(tool_id)
        expect(definition.allowed_scopes).to eq([Captain::ToolAccess::SCOPE_ASSISTANT])
        expect(definition.idempotent).to be(true)
        expect(definition.risk_level).to eq('low')
      end

      agent_tool_ids = Captain::ToolRegistry.tools_for_scope(Captain::ToolAccess::SCOPE_AGENT).pluck(:id)
      expect(agent_tool_ids).to include('search_canned_responses')
      expect(agent_tool_ids).not_to include(*read_tool_ids)
    end
  end
end
# rubocop:enable RSpec/DescribeClass
