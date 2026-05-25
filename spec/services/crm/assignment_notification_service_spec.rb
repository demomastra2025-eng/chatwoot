require 'rails_helper'

RSpec.describe Crm::AssignmentNotificationService do
  let(:account) { create(:account) }
  let(:actor) { create(:user, account: account, role: :administrator) }
  let(:assignee) { create(:user, account: account, role: :agent) }
  let(:task) { create(:crm_task, account: account, assignee: assignee) }

  it 'creates an assignment notification for the assigned user' do
    described_class.new(
      account: account,
      record: task,
      user: assignee,
      notification_type: 'task_assignment',
      actor: actor
    ).perform

    notification = assignee.notifications.find_by!(notification_type: 'task_assignment')
    expect(notification.primary_actor).to eq(task)
    expect(notification.secondary_actor).to eq(actor)
    expect(notification.account).to eq(account)
  end

  it 'skips self-assignment notifications' do
    described_class.new(
      account: account,
      record: task,
      user: actor,
      notification_type: 'task_assignment',
      actor: actor
    ).perform

    expect(actor.notifications.where(notification_type: 'task_assignment')).to be_empty
  end
end
