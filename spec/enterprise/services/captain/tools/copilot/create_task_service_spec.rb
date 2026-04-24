require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::CreateTaskService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let!(:deal) { create(:crm_deal, account: account, originating_conversation_id: conversation.id) }
  let(:service) { described_class.new(assistant, user: user, conversation: conversation) }

  before do
    account.enable_features!('crm_tasks')
    account.enable_features!('crm_deals')
    create(:crm_field_definition, account: account, entity_kind: 'task', key: 'source', label: 'Source', field_type: 'text')
    create(:crm_field_definition, account: account, entity_kind: 'task', key: 'channel', label: 'Channel', field_type: 'text')
  end

  describe '#execute' do
    it 'creates a task using object custom_attributes' do
      service.execute(
        title: 'Call back tomorrow',
        priority: 'high',
        custom_attributes: { 'source' => 'captain', 'channel' => 'telegram' }
      )

      task = account.crm_tasks.order(:id).last

      expect(task.title).to eq('Call back tomorrow')
      expect(task.priority).to eq('high')
      expect(task.deal_id).to eq(deal.id)
      expect(task.originating_conversation_id).to eq(conversation.id)
      expect(task.custom_attributes).to include(
        'source' => 'captain',
        'channel' => 'telegram'
      )
    end
  end
end
