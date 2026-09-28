require 'rails_helper'

RSpec.describe Captain::Conversation::ReplayDeferredCloudDeliveriesJob do
  let(:account) { create(:account) }
  let(:channel) do
    create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud',
                              validate_provider_config: false, sync_templates: false)
  end
  let(:conversation) { create(:conversation, account: account, inbox: channel.inbox, status: :pending) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:incoming) { create(:message, account: account, conversation: conversation, inbox: channel.inbox, message_type: :incoming) }
  let(:fence) do
    { control_generation: conversation.current_captain_control_generation,
      assistant_id: assistant.id, trigger_message_id: incoming.id, kind: 'reply' }
  end
  let(:next_at) { 1.minute.ago.iso8601 }
  let(:deferred) do
    create(:message, account: account, conversation: conversation, inbox: channel.inbox,
                     sender: assistant, message_type: :outgoing, status: :sent,
                     content_attributes: { whatsapp_cloud_send_retry_count: 1,
                                           whatsapp_cloud_send_retry_next_at: next_at },
                     additional_attributes: { captain_delivery_state: 'deferred', captain_delivery_fence: fence })
  end

  before { create(:captain_inbox, captain_assistant: assistant, inbox: channel.inbox) }

  it 'recovers a committed deferral when the process dies before enqueue' do
    expect { described_class.perform_now }.not_to have_enqueued_job(SendReplyJob)

    deferred
    expect { described_class.perform_now }.to have_enqueued_job(SendReplyJob)
      .with(deferred.id).on_queue('captain_outbound_messages_v2')
  end

  it 'waits until the persisted next-at even if the committed enqueue marker was lost' do
    retry_at = 2.minutes.from_now
    deferred.update!(content_attributes: deferred.content_attributes.merge('whatsapp_cloud_send_retry_next_at' => retry_at.iso8601))
    expect { described_class.perform_now }.not_to have_enqueued_job(SendReplyJob)

    travel_to(retry_at + 1.second) do
      expect { described_class.perform_now }.to have_enqueued_job(SendReplyJob).with(deferred.id)
    end
  end

  it 'leaves a due deferral intact and retries the scan after enqueue failure' do
    deferred
    allow(SendReplyJob).to receive(:perform_later).and_raise(ActiveJob::EnqueueError, 'queue unavailable')
    expect { described_class.perform_now }.to raise_error(ActiveJob::EnqueueError, 'queue unavailable')
    expect(deferred.reload.additional_attributes['captain_delivery_state']).to eq('deferred')

    allow(SendReplyJob).to receive(:perform_later).and_call_original
    expect { described_class.perform_now }.to have_enqueued_job(SendReplyJob).with(deferred.id)
  end

  it 'requeues a lost scheduled job even with a persisted enqueue marker, without duplicating delivery' do
    deferred.update_columns(additional_attributes: deferred.additional_attributes.merge( # rubocop:disable Rails/SkipsModelValidations
      'captain_delivery_retry_enqueued_for' => next_at
    ))
    expect { described_class.perform_now }.to have_enqueued_job(SendReplyJob).with(deferred.id)
    expect { described_class.perform_now }.to have_enqueued_job(SendReplyJob).with(deferred.id)

    service = instance_double(Whatsapp::SendOnWhatsappService)
    allow(Whatsapp::SendOnWhatsappService).to receive(:new).and_return(service)
    allow(service).to receive(:perform) { deferred.update!(source_id: 'accepted-receipt', content_attributes: {}) }
    SendReplyJob.perform_now(deferred.id)
    SendReplyJob.perform_now(deferred.id)
    expect(service).to have_received(:perform).once
    expect(deferred.reload.additional_attributes['captain_delivery_state']).to eq('submitted')
    expect { described_class.perform_now }.not_to have_enqueued_job(SendReplyJob)
  end

  it 'does not enqueue early or replay uncertain and accepted provider outcomes' do
    future = create(:message, account: account, conversation: conversation, inbox: channel.inbox,
                              sender: assistant, message_type: :outgoing, status: :sent,
                              content_attributes: { whatsapp_cloud_send_retry_count: 1,
                                                    whatsapp_cloud_send_retry_next_at: 2.minutes.from_now.iso8601 },
                              additional_attributes: { captain_delivery_state: 'deferred' })
    unknown = deferred
    unknown.update_columns(additional_attributes: unknown.additional_attributes.merge( # rubocop:disable Rails/SkipsModelValidations
      'captain_delivery_state' => 'outcome_unknown'
    ))
    dispatching = create(:message, account: account, conversation: conversation, inbox: channel.inbox,
                                   sender: assistant, message_type: :outgoing, status: :sent,
                                   content_attributes: unknown.content_attributes,
                                   additional_attributes: { captain_delivery_state: 'dispatching' })
    submitted = create(:message, account: account, conversation: conversation, inbox: channel.inbox,
                                 sender: assistant, message_type: :outgoing, status: :sent,
                                 content_attributes: unknown.content_attributes,
                                 additional_attributes: { captain_delivery_state: 'submitted' })
    ambiguous = create(:message, account: account, conversation: conversation, inbox: channel.inbox,
                                 sender: assistant, message_type: :outgoing, status: :sent,
                                 content_attributes: unknown.content_attributes.merge(whatsapp_cloud_delivery_outcome_unknown: true),
                                 additional_attributes: { captain_delivery_state: 'deferred' })
    receipt = create(:message, account: account, conversation: conversation, inbox: channel.inbox,
                               sender: assistant, message_type: :outgoing, status: :sent, source_id: 'provider-receipt',
                               content_attributes: unknown.content_attributes,
                               additional_attributes: { captain_delivery_state: 'deferred' })
    expect([future, dispatching, submitted, ambiguous, receipt]).to all(be_persisted)
    expect { described_class.perform_now }.not_to have_enqueued_job(SendReplyJob)
  end

  it 'leaves non-Captain and non-Cloud messages to their existing delivery paths' do
    regular = create(:message, account: account, conversation: conversation, inbox: channel.inbox,
                               message_type: :outgoing, status: :sent,
                               content_attributes: { whatsapp_cloud_send_retry_count: 1,
                                                     whatsapp_cloud_send_retry_next_at: next_at },
                               additional_attributes: { captain_delivery_state: 'deferred' })
    other_channel = create(:channel_whatsapp, account: account, provider: 'default',
                                              validate_provider_config: false, sync_templates: false)
    other_conversation = create(:conversation, account: account, inbox: other_channel.inbox, status: :pending)
    other = create(:message, account: account, conversation: other_conversation, inbox: other_channel.inbox,
                             sender: assistant, message_type: :outgoing, status: :sent,
                             content_attributes: regular.content_attributes,
                             additional_attributes: { captain_delivery_state: 'deferred' })
    expect([regular, other]).to all(be_persisted)
    expect { described_class.perform_now }.not_to have_enqueued_job(SendReplyJob)
  end
end
