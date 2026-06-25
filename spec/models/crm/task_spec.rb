require 'rails_helper'

RSpec.describe Crm::Task do
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
