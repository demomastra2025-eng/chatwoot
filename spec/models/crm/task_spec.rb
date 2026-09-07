require 'rails_helper'

RSpec.describe Crm::Task do
  it 'uses a database default compatible with the positive position invariant' do
    default = described_class.columns_hash.fetch('position').default

    expect(default.to_i).to eq(1)
  end

  describe 'activity type and outcome' do
    let(:account) { create(:account) }

    it 'accepts configured CRM task activity types and outcomes' do
      task = build(:crm_task, account: account, activity_type: 'task', outcome: 'not_done', outcome_note: 'Client did not join')

      expect(task).to be_valid
    end

    it 'normalizes blank outcome notes' do
      task = build(:crm_task, account: account, outcome_note: '   ')

      task.valid?

      expect(task.outcome_note).to be_nil
    end

    it 'requires a reason for not done outcomes' do
      task = build(:crm_task, account: account, outcome: 'not_done', outcome_note: '   ')

      expect(task).not_to be_valid
      expect(task.errors[:outcome_note]).to be_present
    end

    it 'accepts account-configured custom task activity types' do
      task_type = create(:crm_task_type, account: account, code: 'appointment')
      task = build(:crm_task, account: account, activity_type: 'appointment', task_type: task_type)

      expect(task).to be_valid
      expect(task.activity_type).to eq('appointment')
    end
  end

  describe 'deadline updates' do
    let(:account) { create(:account) }

    it 'rejects an all-day task without a calendar date' do
      task = build(:crm_task, account: account, all_day: true, due_on: nil, due_at: nil)

      expect(task).not_to be_valid
      expect(task.errors[:due_on]).to be_present
    end

    it 'clears the exact start time for an all-day task' do
      task = build(:crm_task, account: account, all_day: true, due_on: Date.new(2026, 9, 4), start_at: Time.zone.now)

      task.valid?

      expect(task.start_at).to be_nil
      expect(task.due_at).to be_nil
      expect(task.schedule_timezone).to eq(account.workspace_working_hours_timezone)
    end

    it 'converts a legacy all-day timestamp into the task schedule timezone' do
      task = build(
        :crm_task,
        account: account,
        all_day: true,
        due_at: Time.iso8601('2026-09-03T23:30:00Z'),
        schedule_timezone: 'Asia/Almaty'
      )

      task.valid?

      expect(task.due_on).to eq(Date.new(2026, 9, 4))
      expect(task.due_at).to be_nil
      expect(task.effective_due_at).to eq(Time.find_zone('Asia/Almaty').local(2026, 9, 4).end_of_day)
    end

    it 'keeps the canonical due_on when a legacy timestamp is also supplied' do
      task = build(
        :crm_task,
        account: account,
        all_day: true,
        due_on: Date.new(2026, 9, 5),
        due_at: Time.iso8601('2026-09-03T23:30:00Z'),
        schedule_timezone: 'Asia/Almaty'
      )

      task.valid?

      expect(task.due_on).to eq(Date.new(2026, 9, 5))
      expect(task.due_at).to be_nil
    end

    it 'allows an unrelated deadline update when a legacy creator no longer belongs to the account' do
      creator = create(:user, account: account)
      task = create(:crm_task, account: account, creator: creator)
      account.account_users.find_by!(user: creator).destroy!

      expect(task.reload.update(due_at: 1.day.from_now)).to be(true)
    end

    it 'still rejects assigning a creator from another account' do
      task = create(:crm_task, account: account)
      other_creator = create(:user, account: create(:account))

      task.creator = other_creator

      expect(task).not_to be_valid
      expect(task.errors[:creator]).to include('must belong to the current account')
    end
  end

  describe 'contact owner sync' do
    let(:account) { create(:account) }
    let(:owner) { create(:user, account: account, role: :agent) }
    let(:new_owner) { create(:user, account: account, role: :agent) }
    let(:contact) { create(:contact, account: account, owner: owner) }

    it 'syncs assignee changes to the primary deal contact' do
      deal = create(:crm_deal, account: account, owner: owner)
      create(:crm_deal_contact, account: account, deal: deal, contact: contact, primary: true)
      task = create(:crm_task, account: account, deal: deal, assignee: owner)

      task.update!(assignee: new_owner)

      expect(contact.reload.owner).to eq(new_owner)
    end

    it 'syncs assignee changes to the originating conversation contact when there is no deal' do
      conversation = create(:conversation, account: account, contact: contact, assignee: owner)
      task = create(:crm_task, account: account, originating_conversation: conversation, assignee: owner)

      task.update!(assignee: new_owner)

      expect(contact.reload.owner).to eq(new_owner)
    end
  end
end
