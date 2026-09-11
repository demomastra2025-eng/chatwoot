require 'rails_helper'

RSpec.describe Reminders::DeliverMaterializedMessageJob do
  it 'runs the appointment provider guard immediately before dispatch' do
    conversation = create(:conversation)
    touch = create(:reminder, account: conversation.account, conversation: conversation, remindable: conversation, status: :completed)
    message = create(
      :message,
      account: conversation.account,
      inbox: conversation.inbox,
      conversation: conversation,
      message_type: :outgoing,
      skip_send_reply: true,
      additional_attributes: { 'touch_id' => touch.id, 'touch_source' => 'touch' }
    )
    touch.update!(metadata: touch.metadata.to_h.merge(Reminder::DELIVERY_MATERIALIZED_MESSAGE_ID_KEY => message.id.to_s))
    guard = instance_double(Reminders::AppointmentProviderGuard)
    allow(Reminders::AppointmentProviderGuard).to receive(:new)
      .with(reminder: touch, phase: :delivery)
      .and_return(guard)
    allow(guard).to receive(:verify).and_return(nil)
    allow(guard).to receive(:perform).with(verification: nil) do
      expect(ActiveRecord::Base.connection.transaction_open?).to be(true)
      Reminders::AppointmentProviderGuard::STOP
    end
    allow(SendReplyJob).to receive(:perform_now)

    described_class.perform_now(touch.id, message.id, touch.processing_claim_token)

    expect(SendReplyJob).not_to have_received(:perform_now)
  end

  it 'dispatches a materialized message once across duplicate jobs' do
    conversation = create(:conversation)
    touch = create(
      :reminder,
      account: conversation.account,
      conversation: conversation,
      remindable: conversation,
      status: :pending,
      body: 'Dispatch once'
    )
    active_claim = touch.mark_processing!
    message = create(
      :message,
      account: conversation.account,
      inbox: conversation.inbox,
      conversation: conversation,
      message_type: :outgoing,
      skip_send_reply: true,
      additional_attributes: { 'touch_id' => touch.id, 'touch_source' => 'touch' }
    )
    touch.mark_delivery_materialized!(message.id)
    allow(SendReplyJob).to receive(:perform_now)

    2.times { described_class.perform_now(touch.id, message.id, active_claim) }

    expect(SendReplyJob).to have_received(:perform_now).with(message.id).once
    expect(touch.reload).to be_delivery_dispatched_for(message.id)
    expect(touch.processing_claim_token).to be_nil
    expect(touch.processing_started_at).to be_nil
  end

  it 'checks provider freshness before row locks and applies the result under the appointment lock' do
    conversation = create(:conversation)
    appointment = create(:scheduling_appointment, account: conversation.account, conversation: conversation)
    touch = create(
      :reminder,
      account: conversation.account,
      conversation: conversation,
      remindable: appointment,
      status: :pending,
      body: 'Dispatch while current'
    )
    active_claim = touch.mark_processing!
    message = create(
      :message,
      account: conversation.account,
      inbox: conversation.inbox,
      conversation: conversation,
      message_type: :outgoing,
      skip_send_reply: true,
      additional_attributes: { 'touch_id' => touch.id, 'touch_source' => 'touch' }
    )
    touch.mark_delivery_materialized!(message.id)
    appointment_lock_held = false
    allow(Reminder).to receive(:find).with(touch.id).and_return(touch)
    allow(appointment).to receive(:with_lock).and_wrap_original do |original, &block|
      original.call do
        appointment_lock_held = true
        block.call
      ensure
        appointment_lock_held = false
      end
    end
    guard = instance_double(Reminders::AppointmentProviderGuard)
    verification = instance_double(Integrations::Medelement::AppointmentFreshnessVerifier::Result)
    allow(Reminders::AppointmentProviderGuard).to receive(:new).and_return(guard)
    allow(guard).to receive(:verify) do
      expect(appointment_lock_held).to be(false)
      verification
    end
    allow(guard).to receive(:perform).with(verification: verification) do
      expect(appointment_lock_held).to be(true)
      Reminders::AppointmentProviderGuard::CONTINUE
    end
    allow(SendReplyJob).to receive(:perform_now) { expect(appointment_lock_held).to be(false) }

    described_class.perform_now(touch.id, message.id, active_claim)

    expect(SendReplyJob).to have_received(:perform_now).with(message.id).once
  end

  it 'rechecks local cancellation after renewing the delivery mutex' do
    conversation = create(:conversation)
    appointment = create(:scheduling_appointment, account: conversation.account, conversation: conversation)
    touch = create(
      :reminder,
      account: conversation.account,
      conversation: conversation,
      remindable: appointment,
      status: :pending,
      body: 'Do not dispatch after cancellation'
    )
    active_claim = touch.mark_processing!
    message = create(
      :message,
      account: conversation.account,
      inbox: conversation.inbox,
      conversation: conversation,
      message_type: :outgoing,
      skip_send_reply: true,
      additional_attributes: { 'touch_id' => touch.id, 'touch_source' => 'touch' }
    )
    touch.mark_delivery_materialized!(message.id)
    lock_manager = instance_double(Redis::LockManager, lock: true, unlock: true)
    allow(Redis::LockManager).to receive(:new).and_return(lock_manager)
    allow(lock_manager).to receive(:renew) do
      appointment.update!(status: :cancelled)
      true
    end
    allow(SendReplyJob).to receive(:perform_now)

    described_class.perform_now(touch.id, message.id, active_claim)

    expect(SendReplyJob).not_to have_received(:perform_now)
    expect(touch.reload).to be_cancelled
    expect(touch.last_error).to eq('local_appointment_cancelled')
  end

  it 're-enqueues delivery when another worker owns the delivery mutex' do
    conversation = create(:conversation)
    touch = create(:reminder, account: conversation.account, conversation: conversation, remindable: conversation, status: :completed)
    message = create(
      :message,
      account: conversation.account,
      inbox: conversation.inbox,
      conversation: conversation,
      message_type: :outgoing,
      skip_send_reply: true,
      additional_attributes: { 'touch_id' => touch.id, 'touch_source' => 'touch' }
    )
    touch.update!(metadata: touch.metadata.to_h.merge(Reminder::DELIVERY_MATERIALIZED_MESSAGE_ID_KEY => message.id.to_s))
    allow(Redis::Alfred).to receive(:set).and_return(false)
    allow(SendReplyJob).to receive(:perform_now)

    expect do
      described_class.perform_now(touch.id, message.id, touch.processing_claim_token)
    end.to have_enqueued_job(described_class)
      .with(touch.id, message.id, touch.processing_claim_token)
      .on_queue('outbound_messages')
    expect(SendReplyJob).not_to have_received(:perform_now)
  end

  it 'releases the delivery mutex and preserves the claim when provider dispatch fails' do
    conversation = create(:conversation)
    touch = create(
      :reminder,
      account: conversation.account,
      conversation: conversation,
      remindable: conversation,
      status: :pending,
      body: 'Retry after provider failure'
    )
    active_claim = touch.mark_processing!
    message = create(
      :message,
      account: conversation.account,
      inbox: conversation.inbox,
      conversation: conversation,
      message_type: :outgoing,
      skip_send_reply: true,
      additional_attributes: { 'touch_id' => touch.id, 'touch_source' => 'touch' }
    )
    touch.mark_delivery_materialized!(message.id)
    lock_key = format(Redis::Alfred::REMINDER_DELIVERY_MUTEX, reminder_id: touch.id)
    allow(SendReplyJob).to receive(:perform_now).and_raise(StandardError, 'provider unavailable')

    expect do
      described_class.perform_now(touch.id, message.id, active_claim)
    end.to raise_error(StandardError, 'provider unavailable')

    expect(Redis::Alfred.get(lock_key)).to be_nil
    expect(touch.reload).not_to be_delivery_dispatched_for(message.id)
    expect(touch.processing_claim_token).to eq(active_claim)
  end

  it 'fails the reminder instead of recording a failed provider delivery as dispatched' do
    conversation = create(:conversation)
    touch = create(
      :reminder,
      account: conversation.account,
      conversation: conversation,
      remindable: conversation,
      status: :pending,
      body: 'Surface provider failure'
    )
    active_claim = touch.mark_processing!
    message = create(
      :message,
      account: conversation.account,
      inbox: conversation.inbox,
      conversation: conversation,
      message_type: :outgoing,
      skip_send_reply: true,
      additional_attributes: { 'touch_id' => touch.id, 'touch_source' => 'touch' }
    )
    touch.mark_delivery_materialized!(message.id)
    allow(SendReplyJob).to receive(:perform_now) do
      message.update!(status: :failed, external_error: 'recipient unavailable')
    end

    described_class.perform_now(touch.id, message.id, active_claim)

    expect(touch.reload).to be_failed
    expect(touch).not_to be_delivery_dispatched_for(message.id)
    expect(touch.last_error).to eq('recipient unavailable')
    expect(touch.processing_claim_token).to eq(active_claim)
  end

  it 'fails an unconfirmed WhatsApp delivery with no provider message id' do
    account = create(:account, limits: { non_web_inboxes: ChatwootApp.max_limit })
    channel = create(
      :channel_whatsapp,
      account: account,
      provider: 'whatsapp_cloud',
      sync_templates: false,
      validate_provider_config: false
    )
    conversation = create(:conversation, account: account, inbox: channel.inbox)
    create(:message, account: account, inbox: channel.inbox, conversation: conversation, message_type: :incoming)
    touch = create(
      :reminder,
      account: account,
      conversation: conversation,
      remindable: conversation,
      status: :pending,
      body: 'Require provider acknowledgement'
    )
    active_claim = touch.mark_processing!
    message = create(
      :message,
      account: account,
      inbox: channel.inbox,
      conversation: conversation,
      message_type: :outgoing,
      skip_send_reply: true,
      source_id: nil,
      additional_attributes: { 'touch_id' => touch.id, 'touch_source' => 'touch' }
    )
    touch.mark_delivery_materialized!(message.id)
    allow(SendReplyJob).to receive(:perform_now)

    described_class.perform_now(touch.id, message.id, active_claim)

    expect(message.reload).to be_failed
    expect(message.external_error).to eq(described_class::UNCONFIRMED_PROVIDER_DELIVERY)
    expect(touch.reload).to be_failed
    expect(touch).not_to be_delivery_dispatched_for(message.id)
  end

  it 'suppresses duplicate reminder dispatch after an unknown 360Dialog outcome' do
    channel = create(:channel_whatsapp, sync_templates: false, validate_provider_config: false)
    conversation = create(:conversation, account: channel.account, inbox: channel.inbox)
    create(:message, account: channel.account, inbox: channel.inbox, conversation: conversation, message_type: :incoming)
    touch = create(
      :reminder,
      account: channel.account,
      conversation: conversation,
      remindable: conversation,
      status: :pending,
      body: 'Do not duplicate an ambiguous send'
    )
    active_claim = touch.mark_processing!
    message = create(
      :message,
      account: channel.account,
      inbox: channel.inbox,
      conversation: conversation,
      message_type: :outgoing,
      skip_send_reply: true,
      source_id: nil,
      additional_attributes: { 'touch_id' => touch.id, 'touch_source' => 'touch' }
    )
    touch.mark_delivery_materialized!(message.id)
    allow(SendReplyJob).to receive(:perform_now) do
      message.update!(
        status: :sent,
        content_attributes: { Whatsapp::Providers::Whatsapp360DialogService::DELIVERY_OUTCOME_UNKNOWN_KEY => true }
      )
    end

    2.times { described_class.perform_now(touch.id, message.id, active_claim) }

    expect(SendReplyJob).to have_received(:perform_now).with(message.id).once
    expect(touch.reload).to be_delivery_dispatched_for(message.id)
  end
end
