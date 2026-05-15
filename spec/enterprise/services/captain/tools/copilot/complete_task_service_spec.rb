require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::CompleteTaskService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:service) { described_class.new(assistant, user: user) }

  before do
    account.enable_features!('crm_tasks')
  end

  describe '#execute' do
    it 'marks an account task as done by task id' do
      open_status = create(:crm_task_status, account: account, name: 'Todo', code: 'todo', category: 'open')
      done_status = create(:crm_task_status, account: account, name: 'Done', code: 'done', category: 'done')
      task = create(:crm_task, account: account, status: open_status)

      payload = JSON.parse(service.execute(task_id: task.id))

      expect(payload).to include('action' => 'complete_task')
      expect(payload.fetch('task')).to include(
        'id' => task.id,
        'status_id' => done_status.id,
        'completed_at' => be_present
      )
      expect(task.reload.status_id).to eq(done_status.id)
      expect(task.completed_at).to be_present
    end

    it 'does not complete tasks from another account' do
      other_account = create(:account)
      other_status = create(:crm_task_status, account: other_account, name: 'Todo', code: 'todo', category: 'open')
      other_task = create(:crm_task, account: other_account, status: other_status)

      result = service.execute(task_id: other_task.id)

      expect(result).to include('Task not found')
      expect(other_task.reload.completed_at).to be_nil
    end
  end
end
