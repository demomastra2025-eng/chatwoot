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
    allow(guard).to receive(:perform) do
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

  it 'holds the appointment lock across the final provider guard and dispatch' do
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
    allow(Reminders::AppointmentProviderGuard).to receive(:new).and_return(guard)
    allow(guard).to receive(:perform) do
      expect(appointment_lock_held).to be(true)
      Reminders::AppointmentProviderGuard::CONTINUE
    end
    allow(SendReplyJob).to receive(:perform_now) { expect(appointment_lock_held).to be(true) }

    described_class.perform_now(touch.id, message.id, active_claim)

    expect(SendReplyJob).to have_received(:perform_now).with(message.id).once
  end
end
