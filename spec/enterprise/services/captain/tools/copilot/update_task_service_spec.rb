require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::UpdateTaskService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let!(:task) do
    create(
      :crm_task,
      account: account,
      originating_conversation_id: conversation.id,
      custom_attributes: { 'source' => 'site' }
    )
  end
  let(:service) { described_class.new(assistant, user: user, conversation: conversation) }

  before do
    account.enable_features!('crm_tasks')
    create(:crm_field_definition, account: account, entity_kind: 'task', key: 'source', label: 'Source', field_type: 'text')
    create(:crm_field_definition, account: account, entity_kind: 'task', key: 'playbook', label: 'Playbook', field_type: 'text')
  end

  describe '#execute' do
    it 'updates the current task using JSON custom_attributes' do
      service.execute(priority: 'urgent', custom_attributes: { source: 'captain', playbook: 'recovery' }.to_json)

      task.reload

      expect(task.priority).to eq('urgent')
      expect(task.custom_attributes).to include(
        'source' => 'captain',
        'playbook' => 'recovery'
      )
    end
  end
end
