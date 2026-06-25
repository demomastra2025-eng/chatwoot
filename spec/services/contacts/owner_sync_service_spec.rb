require 'rails_helper'

RSpec.describe Contacts::OwnerSyncService do
  let(:account) { create(:account) }
  let(:owner) { create(:user, account: account, role: :agent) }
  let(:other_agent) { create(:user, account: account, role: :agent) }
  let(:contact) { create(:contact, account: account, owner: nil) }

  describe '#perform' do
    it 'syncs a contact owner to existing conversations, communication thread, and primary deal', :aggregate_failures do
      conversation_without_assignee = create(:conversation, account: account, contact: contact, assignee: nil)
      conversation_with_other_assignee = create(:conversation, account: account, contact: contact, assignee: other_agent)
      other_contact_conversation = create(:conversation, account: account, assignee: other_agent)
      create(:inbox_member, inbox: conversation_without_assignee.inbox, user: owner)
      create(:inbox_member, inbox: conversation_with_other_assignee.inbox, user: owner)
      thread = create(:communication_thread, account: account, contact: contact, assignee: nil)
      other_contact_thread = create(:communication_thread, account: account, assignee: other_agent)
      deal = create(:crm_deal, account: account, owner: nil)
      other_contact_deal = create(:crm_deal, account: account, owner: other_agent)
      create(:crm_deal_contact, account: account, deal: deal, contact: contact, primary: true)
      create(:crm_deal_contact, account: account, deal: other_contact_deal, contact: other_contact_thread.contact, primary: true)
      task = create(:crm_task, account: account, deal: deal, assignee: nil)
      appointment = create(:scheduling_appointment, account: account, contact: contact, owner: nil)
      ownership = create(:assignment_client_ownership,
                         account: account,
                         contact: contact,
                         user: other_agent,
                         assignment_policy: create(:assignment_policy, account: account))
      reminder = create(:reminder, account: account, touch_conversation: conversation_without_assignee)
      task.update!(assignee: other_agent)
      appointment.update!(owner: other_agent)
      reminder.update!(owner: other_agent)

      contact.update!(owner: owner)

      expect(conversation_without_assignee.reload.assignee).to eq(owner)
      expect(conversation_with_other_assignee.reload.assignee).to eq(owner)
      expect(thread.reload.assignee).to eq(owner)
      expect(deal.reload.owner).to eq(owner)
      expect(task.reload.assignee).to eq(owner)
      expect(appointment.reload.owner).to eq(owner)
      expect(ownership.reload.user).to eq(owner)
      expect(reminder.reload.owner).to eq(owner)
      expect(other_contact_conversation.reload.assignee).to eq(other_agent)
      expect(other_contact_thread.reload.assignee).to eq(other_agent)
      expect(other_contact_deal.reload.owner).to eq(other_agent)
    end

    it 'replaces an agent bot assignment with the human contact owner' do
      agent_bot = create(:agent_bot, account: account)
      conversation = create(:conversation, account: account, contact: contact, assignee: nil, assignee_agent_bot: agent_bot)
      create(:inbox_member, inbox: conversation.inbox, user: owner)

      contact.update!(owner: owner)

      expect(conversation.reload.assignee).to eq(owner)
      expect(conversation.assignee_agent_bot).to be_nil
    end

    it 'does not assign a conversation to the contact owner when that owner cannot access the inbox' do
      inaccessible_owner_conversation = create(:conversation, account: account, contact: contact, assignee: other_agent)

      contact.update!(owner: owner)

      expect(inaccessible_owner_conversation.reload.assignee).to eq(other_agent)
      expect(contact.reload.owner).to eq(owner)
    end

    it 'clears synced owners when the contact owner is cleared' do
      contact.update!(owner: owner)
      conversation = create(:conversation, account: account, contact: contact, assignee: owner)
      thread = create(:communication_thread, account: account, contact: contact, assignee: owner)
      deal = create(:crm_deal, account: account, owner: owner)
      create(:crm_deal_contact, account: account, deal: deal, contact: contact, primary: true)
      task = create(:crm_task, account: account, deal: deal, assignee: owner)
      appointment = create(:scheduling_appointment, account: account, contact: contact, owner: owner)
      ownership = create(:assignment_client_ownership,
                         account: account,
                         contact: contact,
                         user: owner,
                         assignment_policy: create(:assignment_policy, account: account))
      reminder = create(:reminder, account: account, touch_conversation: conversation)
      reminder.update!(owner: owner)

      contact.update!(owner: nil)

      expect(conversation.reload.assignee).to be_nil
      expect(thread.reload.assignee).to be_nil
      expect(deal.reload.owner).to be_nil
      expect(task.reload.assignee).to be_nil
      expect(appointment.reload.owner).to be_nil
      expect(AssignmentClientOwnership.exists?(id: ownership.id)).to be(false)
      expect(reminder.reload.owner).to be_nil
    end

    it 'preserves agent bot assignment when clearing the human contact owner' do
      agent_bot = create(:agent_bot, account: account)
      contact.update!(owner: owner)
      conversation = create(:conversation, account: account, contact: contact, assignee: nil, assignee_agent_bot: agent_bot)

      contact.update!(owner: nil)

      expect(conversation.reload.assignee).to be_nil
      expect(conversation.assignee_agent_bot).to eq(agent_bot)
    end

    it 'does not sync deals where the contact is not primary' do
      non_primary_deal = create(:crm_deal, account: account, owner: other_agent)
      create(:crm_deal_contact, account: account, deal: non_primary_deal, contact: contact, primary: false)

      contact.update!(owner: owner)

      expect(non_primary_deal.reload.owner).to eq(other_agent)
    end
  end
end
