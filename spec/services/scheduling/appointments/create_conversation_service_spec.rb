require 'rails_helper'

RSpec.describe Scheduling::Appointments::CreateConversationService do
  let(:account) { create(:account) }
  let(:actor) { create(:user, account: account, role: :agent) }
  let(:appointment) { create(:scheduling_appointment, account: account, contact: contact) }
  let(:contact) { create(:contact, account: account) }
  let(:inbox) { create(:inbox, account: account, channel: create(:channel_api, account: account)) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }
  let(:params) do
    {
      contact_id: contact.id,
      contact_inbox_id: contact_inbox.id,
      inbox_id: inbox.id
    }
  end

  it 'creates and links the conversation in one transaction' do
    result = nil
    contact_inbox
    expect(appointment).to receive(:with_lock).and_call_original

    expect do
      result = described_class.new(
        account: account,
        appointment: appointment,
        inbox: inbox,
        params: params,
        actor: actor
      ).perform
    end.to change(Conversation, :count).by(1)

    conversation = result.reload.conversation
    expect(conversation).to have_attributes(
      account_id: account.id,
      assignee_id: actor.id,
      contact_id: contact.id,
      inbox_id: inbox.id
    )
  end

  it 'returns the existing matching conversation on a retry without creating an orphan' do
    service_params = {
      account: account,
      appointment: appointment,
      inbox: inbox,
      params: params,
      actor: actor
    }
    first_result = described_class.new(**service_params).perform
    original_conversation_id = first_result.conversation_id

    expect do
      second_result = described_class.new(**service_params).perform
      expect(second_result.conversation_id).to eq(original_conversation_id)
    end.not_to change(Conversation, :count)
  end

  it 'preserves the assignee when a single-conversation inbox returns an existing conversation' do
    existing_assignee = create(:user, account: account, role: :agent)
    single_conversation_inbox = create(:channel_telegram, account: account).inbox
    single_conversation_contact_inbox = create(:contact_inbox, contact: contact, inbox: single_conversation_inbox)
    single_conversation_params = params.merge(
      contact_inbox_id: single_conversation_contact_inbox.id,
      inbox_id: single_conversation_inbox.id
    )
    existing_conversation = create(
      :conversation,
      account: account,
      assignee: existing_assignee,
      contact: contact,
      contact_inbox: single_conversation_contact_inbox,
      inbox: single_conversation_inbox
    )

    expect do
      result = described_class.new(
        account: account,
        appointment: appointment,
        inbox: single_conversation_inbox,
        params: single_conversation_params,
        actor: actor
      ).perform

      expect(result.conversation_id).to eq(existing_conversation.id)
    end.not_to change(Conversation, :count)
    expect(existing_conversation.reload.assignee_id).to eq(existing_assignee.id)
  end

  it 'dispatches the appointment update event when linking a conversation' do
    dispatcher = Rails.configuration.dispatcher
    appointment
    other_appointment = create(:scheduling_appointment, account: account, contact: contact, owner: nil)
    updates = []
    allow(dispatcher).to receive(:dispatch) do |event_name, _, data|
      updates << data if event_name == 'appointment.updated' && data[:appointment].id == appointment.id
    end

    described_class.new(
      account: account,
      appointment: appointment,
      inbox: inbox,
      params: params,
      actor: actor
    ).perform

    expect(updates).to contain_exactly(
      hash_including(
        appointment: appointment,
        changed_attributes: hash_including(
          'conversation_id' => [nil, appointment.reload.conversation_id],
          'owner_id' => [nil, actor.id]
        )
      )
    )
    expect(appointment.owner_id).to eq(actor.id)
    expect(other_appointment.reload.owner_id).to eq(actor.id)
    expect(contact.reload.owner_id).to eq(actor.id)
    expect(Current.scheduling_conversation_link_appointment).to be_nil
    durable_updates = AutomationEvent.where(
      subject_type: 'Scheduling::Appointment', subject_id: appointment.id, event_name: 'appointment_updated'
    )
    expect(durable_updates.count).to eq(1)
    expect(durable_updates.first.changes_snapshot).to include('conversation_id' => [nil, appointment.conversation_id])
  end

  it 'does not overwrite a contact changed before the appointment lock is acquired' do
    stale_params = params
    appointment.update!(contact: create(:contact, account: account))

    expect do
      described_class.new(
        account: account,
        appointment: appointment,
        inbox: inbox,
        params: stale_params,
        actor: actor
      ).perform
    end.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('APPOINTMENT_CONTEXT_CHANGED') }

    expect(appointment.reload.contact_id).not_to eq(contact.id)
    expect(appointment.conversation_id).to be_nil
  end

  it 'does not overwrite a different conversation already linked under the appointment lock' do
    other_inbox = create(:inbox, account: account, channel: create(:channel_api, account: account))
    existing_conversation = create(:conversation, account: account, contact: contact, inbox: other_inbox)
    appointment.update!(conversation: existing_conversation)

    expect do
      described_class.new(
        account: account,
        appointment: appointment,
        inbox: inbox,
        params: params,
        actor: actor
      ).perform
    end.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('APPOINTMENT_CONVERSATION_CHANGED') }

    expect(appointment.reload.conversation_id).to eq(existing_conversation.id)
  end

  it 'rolls the conversation back when appointment linking fails' do
    other_appointment = create(:scheduling_appointment, account: account, contact: contact, owner: nil)
    allow(appointment).to receive(:update!).and_raise(ActiveRecord::ActiveRecordError, 'link failed')

    expect do
      described_class.new(
        account: account,
        appointment: appointment,
        inbox: inbox,
        params: params,
        actor: actor
      ).perform
    end.to raise_error(ActiveRecord::ActiveRecordError, 'link failed')
    expect(Conversation.where(account: account).count).to eq(0)
    expect(contact.reload.owner_id).to be_nil
    expect(other_appointment.reload.owner_id).to be_nil
    expect(Current.scheduling_conversation_link_appointment).to be_nil

    contact.update!(owner_id: actor.id)
    expect(appointment.reload.owner_id).to eq(actor.id)
    expect(other_appointment.reload.owner_id).to eq(actor.id)
  end
end
