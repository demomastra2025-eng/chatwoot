require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::SearchConversationsService do
  let(:account) { create(:account) }
  let(:user) { create(:user, role: 'administrator', account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:service) { described_class.new(assistant, user: user) }

  describe '#name' do
    it 'returns the correct service name' do
      expect(service.name).to eq('search_conversations')
    end
  end

  describe '#description' do
    it 'returns the service description' do
      expect(service.description).to eq('Search conversations by status, priority, contact, or labels')
    end
  end

  describe '#parameters' do
    it 'defines the expected parameters' do
      expect(service.parameters.keys).to contain_exactly(:status, :contact_id, :priority, :labels, :limit)
    end
  end

  describe '#active?' do
    context 'when user has conversation_manage permission' do
      let(:custom_role) { create(:custom_role, account: account, permissions: ['conversation_manage']) }
      let(:user) { create(:user, account: account) }

      before do
        account_user = AccountUser.find_by(user: user, account: account)
        account_user.update(role: :agent, custom_role: custom_role)
      end

      it 'returns true' do
        expect(service.active?).to be true
      end
    end

    context 'when user has no relevant conversation permissions' do
      let(:custom_role) { create(:custom_role, account: account, permissions: []) }
      let(:user) { create(:user, account: account) }

      before do
        account_user = AccountUser.find_by(user: user, account: account)
        account_user.update(role: :agent, custom_role: custom_role)
      end

      it 'returns false' do
        expect(service.active?).to be false
      end
    end
  end

  describe '#execute' do
    let(:contact) { create(:contact, account: account, name: 'Aruzhan') }
    let!(:open_conversation) { create(:conversation, account: account, contact: contact, status: 'open', priority: 'high') }
    let!(:resolved_conversation) { create(:conversation, account: account, status: 'resolved', priority: 'low') }

    before do
      open_conversation.label_list.add('sales')
      open_conversation.save!
    end

    it 'returns normalized conversations filtered by status' do
      payload = JSON.parse(service.execute(status: 'open'))

      expect(payload['total_count']).to eq(1)
      expect(payload['filters']).to include('status' => 'open')
      expect(payload['conversations'].first).to include(
        'id' => open_conversation.id,
        'display_id' => open_conversation.display_id,
        'status' => 'open',
        'priority' => 'high'
      )
    end

    it 'supports labels as an array and limit' do
      payload = JSON.parse(service.execute(labels: ['sales'], limit: 1))

      expect(payload['total_count']).to eq(1)
      expect(payload['filters']).to include('labels' => ['sales'])
      expect(payload['conversations'].length).to eq(1)
      expect(payload['conversations'].first['id']).to eq(open_conversation.id)
    end

    it 'returns an empty normalized payload when no conversations are found' do
      payload = JSON.parse(service.execute(status: 'snoozed'))

      expect(payload).to include(
        'total_count' => 0,
        'conversations' => []
      )
    end
  end
end
