require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::SearchTasksService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:service) { described_class.new(assistant, user: user) }
  let(:assignee) { create(:user, account: account) }
  let(:status) { create(:crm_task_status, account: account, name: 'In Progress') }
  let!(:task1) { create(:crm_task, account: account, title: 'Call the clinic', assignee: assignee, status: status, priority: 'high') }
  let!(:task2) { create(:crm_task, account: account, title: 'Prepare quote', priority: 'low') }

  before do
    account.enable_features!('crm_tasks')
  end

  describe '#execute' do
    it 'returns normalized tasks with filters and total_count' do
      payload = JSON.parse(service.execute(query: 'clinic', assignee_id: assignee.id, limit: 1))

      expect(payload['filters']).to include('query' => 'clinic', 'assignee_id' => assignee.id)
      expect(payload['total_count']).to eq(1)
      expect(payload['tasks'].length).to eq(1)
      expect(payload['tasks'].first).to include(
        'id' => task1.id,
        'title' => 'Call the clinic',
        'priority' => 'high',
        'assignee_id' => assignee.id
      )
    end

    it 'ignores zero ID filter placeholders instead of filtering everything out' do
      payload = JSON.parse(service.execute(assignee_id: 0, deal_id: '0'))

      expect(payload['filters']).not_to include('assignee_id', 'deal_id')
      expect(payload['tasks'].map { |task| task['id'] }).to include(task1.id, task2.id)
    end
  end
end
