require 'rails_helper'

RSpec.describe Reminders::AutoCancelOnIncomingService do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }
  let(:conversation) do
    create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
  end

  def incoming_message
    create(
      :message,
      account: account,
      inbox: inbox,
      conversation: conversation,
      sender: contact,
      message_type: :incoming,
      private: false
    )
  end

  it 'cancels open auto-cancel touches after an incoming customer reply' do
    touch = create(
      :reminder,
      account: account,
      conversation: conversation,
      remindable: conversation,
      status: :pending,
      auto_cancel_on_incoming: true,
      metadata: { 'auto_cancel_on_incoming_explicit' => true }
    )
    incoming_message

    described_class.new(message: conversation.messages.incoming.last).perform

    expect(touch.reload).to be_cancelled
    expect(touch.last_error).to eq(Reminders::AutoCancelOnIncomingService::CANCELLED_AFTER_INCOMING_REPLY)
  end

  it 'clears processing_started_at when cancelling a touch that was being processed' do
    touch = create(
      :reminder,
      account: account,
      conversation: conversation,
      remindable: conversation,
      status: :processing,
      processing_started_at: 10.minutes.ago,
      auto_cancel_on_incoming: true,
      metadata: { 'auto_cancel_on_incoming_explicit' => true }
    )
    incoming_message

    described_class.new(message: conversation.messages.incoming.last).perform

    expect(touch.reload).to be_cancelled
    expect(touch.processing_started_at).to be_nil
  end

  it 'does not cancel a processing touch after its outgoing message was materialized' do
    touch = create(
      :reminder,
      account: account,
      conversation: conversation,
      remindable: conversation,
      status: :pending,
      processing_started_at: nil,
      auto_cancel_on_incoming: true,
      metadata: { 'auto_cancel_on_incoming_explicit' => true }
    )
    touch.mark_processing!
    touch.mark_delivery_materialized!(123)
    incoming_message

    described_class.new(message: conversation.messages.incoming.last).perform

    expect(touch.reload).to be_processing
    expect(touch.processing_started_at).to be_present
  end

  it 'does not cancel touches without explicit auto-cancel opt-in' do
    touch = create(
      :reminder,
      account: account,
      conversation: conversation,
      remindable: conversation,
      status: :pending,
      auto_cancel_on_incoming: true
    )
    incoming_message

    described_class.new(message: conversation.messages.incoming.last).perform

    expect(touch.reload).not_to be_cancelled
  end

  it 'skips an unmaterialized appointment step after the current contact replies' do
    account.enable_features!('deferred_touch_materialization')
    appointment = create(
      :scheduling_appointment,
      account: account,
      contact: contact,
      conversation: conversation,
      starts_at: 2.days.from_now,
      ends_at: 2.days.from_now + 30.minutes
    )
    plan = create(
      :reminder_group,
      account: account,
      touches: [
        {
          body: 'Do not send after reply',
          timing_mode: 'relative',
          relative_anchor: 'appointment.starts_at',
          relative_offset_seconds: -1.day.to_i,
          timezone: 'UTC',
          auto_cancel_on_incoming: true
        }
      ]
    )
    enrollment = Reminders::EnrollGroupService.new(
      account: account,
      reminder_group: plan,
      remindable: appointment,
      actor: nil
    ).perform
    message = incoming_message

    cancelled_count = described_class.new(message: message).perform

    expect(cancelled_count).to eq(1)
    expect(enrollment.reload).to be_completed
    expect(enrollment.touch_occurrence_claims.first).to have_attributes(
      status: 'skipped',
      last_error: Reminders::AutoCancelOnIncomingService::CANCELLED_AFTER_INCOMING_REPLY
    )
    expect(account.reminders.where(remindable: appointment)).to be_empty
  end
end
