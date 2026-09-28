require 'rails_helper'

RSpec.describe Captain::Conversation::ReplayKnownDeliveryReceiptsJob do
  let(:account) { create(:account) }
  let(:recovery_job) { Captain::Conversation::RecoverKnownDeliveryReceiptJob }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:channel) { create(:channel_tiktok, account: account) }
  let(:conversation) do
    create(:conversation, account: account, inbox: channel.inbox, status: :pending,
                          additional_attributes: { conversation_id: 'tt-replay-1' })
  end
  let(:client) { instance_double(Tiktok::Client) }

  def captain_message(state:, source_id: nil, ack: nil, touch: nil)
    incoming = create(:message, account: account, inbox: channel.inbox, conversation: conversation, message_type: :incoming)
    attributes = {
      'captain_delivery_state' => state,
      'captain_delivery_fence' => {
        control_generation: conversation.current_captain_control_generation,
        assistant_id: assistant.id, trigger_message_id: incoming.id, kind: 'reply'
      }
    }
    attributes['captain_delivery_pending_ack'] = ack if ack
    attributes['touch_id'] = touch.id if touch
    message = create(:message, account: account, inbox: channel.inbox, conversation: conversation,
                               sender: assistant, message_type: :outgoing, status: :sent, source_id: source_id,
                               skip_send_reply: true, additional_attributes: attributes)
    touch&.mark_delivery_materialized!(message.id)
    message
  end

  before do
    create(:captain_inbox, captain_assistant: assistant, inbox: channel.inbox)
    allow(Tiktok::Client).to receive(:new).and_return(client)
    allow(client).to receive(:send_text_message)
  end

  it 'recovers a committed TikTok receipt without the original job or any new provider POST, after grace' do
    reminder = create(:reminder, account: account, touch_conversation: conversation)
    message = captain_message(state: 'dispatching', source_id: 'tt-before-crash', touch: reminder)

    expect { described_class.perform_now }.not_to have_enqueued_job(SendReplyJob)
    travel 2.minutes do
      expect { described_class.perform_now }.to have_enqueued_job(SendReplyJob).with(message.id).on_queue('captain_outbound_messages_v2')
      SendReplyJob.perform_now(message.id)
    end

    expect(message.reload).to be_delivered
    expect(message.additional_attributes['captain_delivery_state']).to eq('submitted')
    expect(reminder.reload.delivery_stage).to eq('delivered')
    expect(client).not_to have_received(:send_text_message)
    expect { described_class.perform_now }.not_to have_enqueued_job(SendReplyJob)
  end

  it 'reconciles a lost submitted pending acknowledgement without provider I/O, preserving read' do
    reminder = create(:reminder, account: account, touch_conversation: conversation)
    message = captain_message(state: 'submitted', ack: { 'status' => 'delivered' }, touch: reminder)
    Messages::StatusUpdateService.new(message, 'read').perform

    travel 2.minutes do
      expect { described_class.perform_now }.to have_enqueued_job(SendReplyJob).with(message.id)
      SendReplyJob.perform_now(message.id)
    end

    expect(message.reload).to be_read
    expect(message.additional_attributes).not_to have_key('captain_delivery_pending_ack')
    expect(reminder.reload.delivery_stage).to eq('read')
    expect(client).not_to have_received(:send_text_message)
  end

  it 'handles a receipt after human takeover without approving delivery or calling the provider' do
    message = captain_message(state: 'dispatching', source_id: 'tt-before-takeover')
    message.conversation.activate_captain_human_control!(source: 'agent_reply', actor: create(:user, account: account))

    travel 2.minutes do
      expect { described_class.perform_now }.to have_enqueued_job(SendReplyJob).with(message.id)
      SendReplyJob.perform_now(message.id)
    end

    expect(message.reload.additional_attributes['captain_delivery_state']).to eq('outcome_unknown')
    expect(message).to be_failed
    expect(client).not_to have_received(:send_text_message)
  end

  it 'finalizes a completed reminder after the original wrapper was lost even when the ACK was already applied' do
    reminder = create(:reminder, account: account, touch_conversation: conversation)
    claim = reminder.mark_processing!
    message = captain_message(state: 'submitted', ack: { 'status' => 'delivered' }, touch: reminder)
    reminder.update!(status: :completed)
    SendReplyJob.perform_now(message.id) # The provider ACK commits but the wrapper never marks its handoff.
    expect(reminder.reload.delivery_stage).to eq('delivered')
    expect(reminder).not_to be_delivery_dispatched_for(message.id)

    travel 2.minutes do
      expect { described_class.perform_now }.to have_enqueued_job(recovery_job).with(message.id, reminder.id, claim)
      recovery_job.perform_now(message.id, reminder.id, claim)
    end

    expect(reminder.reload).to be_delivery_dispatched_for(message.id)
    expect(reminder.delivery_stage).to eq('delivered')
    expect(reminder.processing_claim_token).to be_nil
    expect(client).not_to have_received(:send_text_message)
  end

  it 'finishes a pending reminder as provider_unknown when a persisted TikTok receipt races human takeover' do
    reminder = create(:reminder, account: account, touch_conversation: conversation)
    claim = reminder.mark_processing!
    message = captain_message(state: 'dispatching', source_id: 'tt-before-human', touch: reminder)
    message.conversation.activate_captain_human_control!(source: 'agent_reply', actor: create(:user, account: account))

    travel 2.minutes do
      expect { described_class.perform_now }.to have_enqueued_job(recovery_job).with(message.id, reminder.id, claim)
      recovery_job.perform_now(message.id, reminder.id, claim)
    end

    expect(message.reload.additional_attributes['captain_delivery_state']).to eq('outcome_unknown')
    expect(reminder.reload).not_to be_failed
    expect(reminder).to be_delivery_dispatched_for(message.id)
    expect(reminder.delivery_stage).to eq('provider_unknown')
    expect(reminder.processing_claim_token).to be_nil
    expect(client).not_to have_received(:send_text_message)
  end

  it 'ignores ambiguous dispatches with no receipt and never replays uncertain outcomes' do
    no_receipt = captain_message(state: 'dispatching')
    unknown = captain_message(state: 'outcome_unknown', source_id: 'unconfirmed')
    expect([no_receipt, unknown]).to all(be_persisted)

    travel 2.minutes do
      expect { described_class.perform_now }.not_to have_enqueued_job(SendReplyJob)
    end
    expect(client).not_to have_received(:send_text_message)
  end

  it 'retries a pending acknowledgement after a reconciliation exception without provider resend' do
    message = captain_message(state: 'submitted', ack: { 'status' => 'delivered' })
    allow(Messages::StatusUpdateService).to receive(:new).and_raise('status unavailable')

    travel 2.minutes do
      expect { described_class.perform_now }.to have_enqueued_job(SendReplyJob).with(message.id)
      expect { SendReplyJob.perform_now(message.id) }.to raise_error('status unavailable')
      expect(message.reload.additional_attributes['captain_delivery_pending_ack']).to eq('status' => 'delivered')
      allow(Messages::StatusUpdateService).to receive(:new).and_call_original
      expect { described_class.perform_now }.to have_enqueued_job(SendReplyJob).with(message.id)
      SendReplyJob.perform_now(message.id)
    end

    expect(message.reload).to be_delivered
    expect(client).not_to have_received(:send_text_message)
  end

  it 'recovers an explicit failed provider acknowledgement and the reminder after a lost job' do
    reminder = create(:reminder, account: account, touch_conversation: conversation)
    message = captain_message(state: 'provider_failed', ack: { 'status' => 'failed', 'error' => 'recipient rejected' }, touch: reminder)

    travel 2.minutes do
      expect { described_class.perform_now }.to have_enqueued_job(SendReplyJob).with(message.id)
      SendReplyJob.perform_now(message.id)
    end

    expect(message.reload).to be_failed
    expect(message.external_error).to eq('recipient rejected')
    expect(reminder.reload).to be_failed
    expect(reminder.delivery_stage).to eq('failed')
    expect(client).not_to have_received(:send_text_message)
  end

  context 'with a LINE acknowledgement' do
    let(:channel) { create(:channel_line, account: account) }

    it 'recovers only a committed pending acknowledgement without sending again' do
      allow(Line::Bot::Client).to receive(:new).and_raise('LINE must not be called')
      receipt_without_ack = captain_message(state: 'dispatching', source_id: 'line-unconfirmed')
      message = captain_message(state: 'submitted', ack: { 'status' => 'delivered' })

      travel 2.minutes do
        expect { described_class.perform_now }.to have_enqueued_job(SendReplyJob).with(message.id)
        SendReplyJob.perform_now(message.id)
      end

      expect(message.reload).to be_delivered
      expect(receipt_without_ack.reload.additional_attributes['captain_delivery_state']).to eq('dispatching')
      expect(Line::Bot::Client).not_to have_received(:new)
    end

    it 'recovers a completed reminder after its LINE ACK was already cleared, without a provider message id' do
      allow(Line::Bot::Client).to receive(:new).and_raise('LINE must not be called')
      reminder = create(:reminder, account: account, touch_conversation: conversation)
      claim = reminder.mark_processing!
      message = captain_message(state: 'submitted', ack: { 'status' => 'delivered' }, touch: reminder)
      reminder.update!(status: :completed)
      SendReplyJob.perform_now(message.id)

      travel 2.minutes do
        expect { described_class.perform_now }.to have_enqueued_job(recovery_job).with(message.id, reminder.id, claim)
        recovery_job.perform_now(message.id, reminder.id, claim)
      end

      expect(message.reload.source_id).to be_nil
      expect(reminder.reload).to be_delivery_dispatched_for(message.id)
      expect(reminder.delivery_stage).to eq('delivered')
      expect(Line::Bot::Client).not_to have_received(:new)
    end
  end

  it 'bounds each sweep and eventually reaches the next receipt when the first never resolves' do
    first = captain_message(state: 'dispatching', source_id: 'tt-first')
    second = captain_message(state: 'submitted', ack: { 'status' => 'delivered' })
    stub_const('Captain::Conversation::ReplayKnownDeliveryReceiptsJob::BATCH_SIZE', 1)

    travel 2.minutes do
      expect { described_class.perform_now }.to have_enqueued_job(SendReplyJob).with(first.id)
      expect { described_class.perform_now }.to have_enqueued_job(SendReplyJob).with(second.id)
      expect { described_class.perform_now }.to have_enqueued_job(SendReplyJob).with(first.id)
    end
  end

  it 'rotates a durable reminder cursor past an unresolved reminder instead of starving a confirmed handoff' do
    blocked = create(:reminder, account: account, touch_conversation: conversation)
    blocked.mark_processing!
    captain_message(state: 'dispatching', touch: blocked)
    ready = create(:reminder, account: account, touch_conversation: conversation, body: 'Other receipt for the same conversation')
    claim = ready.mark_processing!
    receipt = captain_message(state: 'submitted', touch: ready)
    ready.update!(status: :completed)
    stub_const('Captain::Conversation::ReplayKnownDeliveryReceiptsJob::BATCH_SIZE', 1)

    travel 2.minutes do
      expect { described_class.perform_now }.not_to have_enqueued_job(recovery_job)
      expect { described_class.perform_now }.to have_enqueued_job(recovery_job).with(receipt.id, ready.id, claim)
      expect { described_class.perform_now }.not_to have_enqueued_job(recovery_job)
    end
  end

  it 'wraps a late old ACK even while a new eligible message arrives for every bounded sweep' do
    old = captain_message(state: 'dispatching')
    ahead = captain_message(state: 'submitted', ack: { 'status' => 'delivered' })
    stub_const('Captain::Conversation::ReplayKnownDeliveryReceiptsJob::BATCH_SIZE', 1)

    travel 2.minutes do
      expect { described_class.perform_now }.to have_enqueued_job(SendReplyJob).with(ahead.id)
      old.update!(additional_attributes: old.additional_attributes.merge(
        'captain_delivery_state' => 'submitted', 'captain_delivery_pending_ack' => { 'status' => 'delivered' }
      ), updated_at: 2.minutes.ago)

      expect do
        3.times do
          fresh = captain_message(state: 'submitted', ack: { 'status' => 'delivered' })
          fresh.update!(updated_at: 2.minutes.ago)
          described_class.perform_now
        end
      end.to have_enqueued_job(SendReplyJob).with(old.id)
    end
  end

  it 'wraps a late old reminder under continuous new materialized deliveries' do
    old = create(:reminder, account: account, touch_conversation: conversation)
    old_claim = old.mark_processing!
    old_message = captain_message(state: 'dispatching', touch: old)
    ahead = create(:reminder, account: account, touch_conversation: conversation, body: 'Ahead of late receipt')
    ahead_claim = ahead.mark_processing!
    ahead_message = captain_message(state: 'submitted', touch: ahead)
    ahead.update!(status: :completed)
    stub_const('Captain::Conversation::ReplayKnownDeliveryReceiptsJob::BATCH_SIZE', 1)

    travel 2.minutes do
      expect { described_class.perform_now }.not_to have_enqueued_job(recovery_job)
      expect { described_class.perform_now }.to have_enqueued_job(recovery_job).with(ahead_message.id, ahead.id, ahead_claim)
      old_message.update!(additional_attributes: old_message.additional_attributes.merge('captain_delivery_state' => 'submitted'))

      expect do
        3.times do |iteration|
          fresh = create(:reminder, account: account, touch_conversation: conversation, body: "New receipt #{iteration}")
          fresh.mark_processing!
          captain_message(state: 'submitted', touch: fresh)
          fresh.update!(status: :completed)
          fresh.update!(updated_at: 2.minutes.ago)
          described_class.perform_now
        end
      end.to have_enqueued_job(recovery_job).with(old_message.id, old.id, old_claim)
    end
  end

  it 'overrides the Message default sort to stream the partial index in primary-key order' do
    sql = described_class.new.send(:candidates).to_sql

    expect(sql).to include('ORDER BY "messages"."id" ASC LIMIT 100')
    expect(sql).not_to include('ORDER BY "messages"."created_at"')
  end
end
