# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CommunicationThreads::RealtimeUpdateJob, type: :job do
  it 'uses the isolated communication-thread realtime queue' do
    expect(described_class.queue_name).to eq('communication_thread_realtime')
  end

  it 'delegates identifier-only arguments to the realtime service' do
    service = instance_double(CommunicationThreads::RealtimeUpdateService, perform: true)
    expect(CommunicationThreads::RealtimeUpdateService).to receive(:new).with(
      communication_thread_id: 10,
      source_conversation_id: 20,
      source_event: 'conversation.updated',
      message_id: 30,
      performer_id: 40
    ).and_return(service)

    described_class.new.perform(
      communication_thread_id: 10,
      source_conversation_id: 20,
      source_event: 'conversation.updated',
      message_id: 30,
      performer_id: 40
    )

    expect(service).to have_received(:perform)
  end

  it 'retries transient record visibility failures' do
    service = instance_double(CommunicationThreads::RealtimeUpdateService)
    allow(CommunicationThreads::RealtimeUpdateService).to receive(:new).and_return(service)
    allow(service).to receive(:perform).and_raise(ActiveRecord::RecordNotFound)

    expect do
      described_class.perform_now(
        communication_thread_id: 10,
        source_conversation_id: 20,
        source_event: 'conversation.updated'
      )
    end.to have_enqueued_job(described_class).with(
      communication_thread_id: 10,
      source_conversation_id: 20,
      source_event: 'conversation.updated'
    )
  end
end
