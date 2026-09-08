require 'rails_helper'

RSpec.describe Contacts::OwnerSyncService do
  let(:account) { create(:account) }
  let(:owner) { create(:user, account: account, role: :agent) }
  let(:other_agent) { create(:user, account: account, role: :agent) }
  let(:contact) { create(:contact, account: account, owner: nil) }

  describe '#perform' do
    it 'syncs relationship ownership without overwriting deal, task, or specialist assignment', :aggregate_failures do
      conversation_without_assignee = create(:conversation, account: account, contact: contact, assignee: nil)
      conversation_with_other_assignee = create(:conversation, account: account, contact: contact, assignee: other_agent)
      other_contact_conversation = create(:conversation, account: account, assignee: other_agent)
      create(:inbox_member, inbox: conversation_without_assignee.inbox, user: owner)
      create(:inbox_member, inbox: conversation_with_other_assignee.inbox, user: owner)
      thread = create(:communication_thread, account: account, contact: contact, assignee: nil)
      other_contact_thread = create(:communication_thread, account: account, assignee: other_agent)
      deal = create(:crm_deal, account: account, owner: other_agent)
      other_contact_deal = create(:crm_deal, account: account, owner: other_agent)
      create(:crm_deal_contact, account: account, deal: deal, contact: contact, primary: true)
      create(:crm_deal_contact, account: account, deal: other_contact_deal, contact: other_contact_thread.contact, primary: true)
      task = create(
        :crm_task,
        account: account,
        deal: deal,
        assignee: nil,
        originating_conversation: conversation_without_assignee
      )
      appointment = create(:scheduling_appointment, account: account, contact: contact)
      appointment_resource = appointment.resource
      ownership = create(:assignment_client_ownership,
                         account: account,
                         contact: contact,
                         user: other_agent,
                         assignment_policy: create(:assignment_policy, account: account))
      reminder = create(:reminder, account: account, touch_conversation: conversation_without_assignee)
      appointment_reminder = create(:reminder, account: account, remindable: appointment, owner: other_agent)
      task.update!(assignee: other_agent)
      deal_reminder = create(
        :reminder,
        account: account,
        remindable: deal,
        touch_conversation: conversation_without_assignee,
        owner: other_agent
      )
      task_reminder = create(
        :reminder,
        account: account,
        remindable: task,
        touch_conversation: conversation_without_assignee,
        owner: other_agent
      )
      reminder.update!(owner: other_agent)

      contact.update!(owner: owner)

      expect(conversation_without_assignee.reload.assignee).to eq(owner)
      expect(conversation_with_other_assignee.reload.assignee).to eq(owner)
      expect(thread.reload.assignee).to eq(owner)
      expect(deal.reload.owner).to eq(other_agent)
      expect(task.reload.assignee).to eq(other_agent)
      expect(appointment.reload.resource).to eq(appointment_resource)
      expect(ownership.reload.user).to eq(owner)
      expect(reminder.reload.owner).to eq(owner)
      expect(appointment_reminder.reload.owner).to eq(owner)
      expect(deal_reminder.reload.owner).to eq(other_agent)
      expect(task_reminder.reload.owner).to eq(other_agent)
      expect(other_contact_conversation.reload.assignee).to eq(other_agent)
      expect(other_contact_thread.reload.assignee).to eq(other_agent)
      expect(other_contact_deal.reload.owner).to eq(other_agent)
    end

    it 'assigns every channel conversation without requiring inbox membership' do
      channel_conversation = create(:conversation, account: account, contact: contact, assignee: other_agent)

      contact.update!(owner: owner)

      expect(channel_conversation.reload.assignee).to eq(owner)
      expect(contact.reload.owner).to eq(owner)
    end

    it 'does not reassign an appointment reminder after delivery was materialized' do
      contact.update!(owner: owner)
      appointment = create(:scheduling_appointment, account: account, contact: contact, created_by: other_agent)
      reminder = create(:reminder, account: account, remindable: appointment, owner: owner)
      reminder.mark_processing!
      reminder.mark_delivery_materialized!(123)

      contact.update!(owner: other_agent)

      expect(reminder.reload.owner).to eq(owner)
    end

    it 'clears synced owners when the contact owner is cleared' do
      contact.update!(owner: owner)
      conversation = create(:conversation, account: account, contact: contact, assignee: owner)
      thread = create(:communication_thread, account: account, contact: contact, assignee: owner)
      deal = create(:crm_deal, account: account, owner: owner)
      create(:crm_deal_contact, account: account, deal: deal, contact: contact, primary: true)
      task = create(
        :crm_task,
        account: account,
        deal: deal,
        assignee: owner,
        originating_conversation: conversation
      )
      appointment = create(:scheduling_appointment, account: account, contact: contact, created_by: other_agent)
      appointment_resource = appointment.resource
      ownership = create(:assignment_client_ownership,
                         account: account,
                         contact: contact,
                         user: owner,
                         assignment_policy: create(:assignment_policy, account: account))
      reminder = create(:reminder, account: account, touch_conversation: conversation)
      appointment_reminder = create(:reminder, account: account, remindable: appointment, owner: owner)
      deal_reminder = create(
        :reminder,
        account: account,
        remindable: deal,
        touch_conversation: conversation,
        owner: owner
      )
      task_reminder = create(
        :reminder,
        account: account,
        remindable: task,
        touch_conversation: conversation,
        owner: owner
      )
      reminder.update!(owner: owner)

      contact.update!(owner: nil)

      expect(conversation.reload.assignee).to be_nil
      expect(thread.reload.assignee).to be_nil
      expect(deal.reload.owner).to eq(owner)
      expect(task.reload.assignee).to eq(owner)
      expect(appointment.reload.resource).to eq(appointment_resource)
      expect(AssignmentClientOwnership.exists?(id: ownership.id)).to be(false)
      expect(reminder.reload.owner).to be_nil
      expect(appointment_reminder.reload.owner).to eq(other_agent)
      expect(deal_reminder.reload.owner).to eq(owner)
      expect(task_reminder.reload.owner).to eq(owner)
    end

    it 'does not sync deals where the contact is not primary' do
      non_primary_deal = create(:crm_deal, account: account, owner: other_agent)
      create(:crm_deal_contact, account: account, deal: non_primary_deal, contact: contact, primary: false)

      contact.update!(owner: owner)

      expect(non_primary_deal.reload.owner).to eq(other_agent)
    end
  end
end
