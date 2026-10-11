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
