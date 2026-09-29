require 'rails_helper'

RSpec.describe Notification::RemoveDuplicateNotificationJob do
  let(:user) { create(:user) }
  let(:conversation) { create(:conversation) }

  it 'enqueues the job' do
    duplicate_notification = create(:notification, user: user, notification_type: 'conversation_creation', primary_actor: conversation)
    expect do
      described_class.perform_later(duplicate_notification)
    end.to have_enqueued_job(described_class)
      .on_queue('default')
  end

  it 'removes duplicate notifications' do
    create(:notification, user: user, notification_type: 'conversation_creation', primary_actor: conversation)
    duplicate_notification = create(:notification, user: user, notification_type: 'conversation_creation', primary_actor: conversation)

    described_class.perform_now(duplicate_notification)
    expect(Notification.count).to eq(1)
  end

  it 'keeps the notification of another actor type that shares the id' do
    account = conversation.account
    task = create(:crm_task, id: conversation.id, account: account)
    conversation_notification = create(:notification, user: user, account: account,
                                                      notification_type: 'conversation_creation', primary_actor: conversation)
    task_notification = create(:notification, user: user, account: account,
                                              notification_type: 'task_assignment', primary_actor: task)

    described_class.perform_now(task_notification)

    expect(Notification.where(id: [conversation_notification.id, task_notification.id]).count).to eq(2)
  end
end
