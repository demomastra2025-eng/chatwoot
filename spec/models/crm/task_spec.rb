require 'rails_helper'

RSpec.describe Crm::Task do
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

    it 'rejects unknown task activity types' do
      task = build(:crm_task, account: account, activity_type: 'appointment')

      expect(task).not_to be_valid
      expect(task.errors[:activity_type]).to be_present
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
