require 'rails_helper'

RSpec.describe ActionCableBroadcastJob, type: :job do
  it 'rehydrates contact conversation updates without restoring AI traces' do
    account = create(:account)
    conversation = create(:conversation, account: account)
    assistant = create(:captain_assistant, account: account, description: 'Private agent instructions')
    create(
      :message, account: account, inbox: conversation.inbox, conversation: conversation,
                message_type: :outgoing, sender: assistant,
                additional_attributes: { 'captain_trace' => { 'reasoning' => 'Private reasoning' } }
    )
    data = { account_id: account.id, id: conversation.display_id, external_payload: true }

    payload = described_class.new.send(:prepare_broadcast_data, 'conversation.updated', data)

    expect(payload[:messages].last[:additional_attributes]).not_to have_key('captain_trace')
    expect(payload[:messages].last[:sender]).not_to have_key(:description)
    expect(payload).not_to have_key(:external_payload)
    expect(conversation.push_event_data[:messages].last[:additional_attributes]).to have_key('captain_trace')
  end

  it 'rehydrates the latest dashboard appointment statuses after a queued snapshot became stale with communication threads disabled' do
    account = create(:account)
    account.enable_features!('scheduling')
    account.disable_features!('communication_threads')
    conversation = create(:conversation, account: account)
    appointment = create(:scheduling_appointment, account: account, conversation: conversation, contact: conversation.contact, status: 'scheduled')
    queued_data = { account_id: account.id, id: conversation.display_id, scheduling_appointment_statuses: [{ status: 'scheduled', count: 1 }] }

    appointment.update!(status: 'confirmed')
    payload = described_class.new.send(:prepare_broadcast_data, 'conversation.updated', queued_data)

    expect(payload[:scheduling_appointment_statuses]).to eq([{ status: 'confirmed', count: 1 }])
    expect(payload).to include(account_id: account.id, id: conversation.display_id)
    expect(queued_data[:scheduling_appointment_statuses]).to eq([{ status: 'scheduled', count: 1 }])
  end

  it 'does not expose requested dashboard appointment statuses in an external conversation payload' do
    account = create(:account)
    account.enable_features!('scheduling')
    conversation = create(:conversation, account: account)
    create(:scheduling_appointment, account: account, contact: conversation.contact, status: 'confirmed')
    queued_data = { account_id: account.id, id: conversation.display_id, external_payload: true,
                    scheduling_appointment_statuses: [{ status: 'confirmed', count: 1 }] }

    payload = described_class.new.send(:prepare_broadcast_data, 'conversation.updated', queued_data)

    expect(payload).not_to have_key(:scheduling_appointment_statuses)
    expect(payload).not_to have_key(:external_payload)
  end

  it 'clears a requested appointment status snapshot when scheduling was disabled after enqueue' do
    account = create(:account)
    account.disable_features!('scheduling')
    conversation = create(:conversation, account: account)
    queued_data = { account_id: account.id, id: conversation.display_id, scheduling_appointment_statuses: [{ status: 'confirmed', count: 1 }] }

    payload = described_class.new.send(:prepare_broadcast_data, 'conversation.updated', queued_data)

    expect(payload[:scheduling_appointment_statuses]).to eq([])
  end

  %w[message.created message.updated conversation.updated contact.updated notification.created].each do |event_name|
    it "routes #{event_name} broadcasts to the isolated broadcast queue" do
      job = described_class.new([], event_name, {})

      expect(job.queue_name).to eq('action_cable_realtime')
    end
  end

  it 'preserves the dedicated communication-thread queue' do
    job = described_class.new([], 'communication_thread.updated', {})

    expect(job.queue_name).to eq('communication_thread_realtime')
  end

  it 'preserves explicit telephony queue overrides' do
    job = described_class.set(queue: :telephony_realtime).perform_later([], 'message.created', {})

    expect(job.queue_name).to eq('telephony_realtime')
  end
end
