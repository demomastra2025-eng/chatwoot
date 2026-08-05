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
    expect(touch.metadata).to include(
      Reminders::IncomingReplyCancellationService::CANCELLED_VIA_KEY => 'incoming_reply',
      Reminders::IncomingReplyCancellationService::CANCELLED_BY_MESSAGE_ID_KEY => conversation.messages.incoming.last.id
    )
  end

  it 'preserves an automation touch caused by the current incoming message' do
    message = incoming_message
    rule = create(:automation_rule, account: account)
    touch = create(
      :reminder,
      account: account,
      conversation: conversation,
      remindable: conversation,
      status: :pending,
      auto_cancel_on_incoming: true,
      metadata: { 'auto_cancel_on_incoming_explicit' => true }
    )
    touch.mark_automation_provenance!(rule, trigger_message: message, action_key: 'legacy-index:0')

    cancelled_count = described_class.new(message: message, event_timestamp: message.created_at).perform

    expect(cancelled_count).to eq(0)
    expect(touch.reload).to be_pending
  end

  it 'cancels a touch caused by an earlier incoming message' do
    trigger_message = incoming_message
    rule = create(:automation_rule, account: account)
    touch = create(
      :reminder,
      account: account,
      conversation: conversation,
      remindable: conversation,
      status: :pending,
      auto_cancel_on_incoming: true,
      metadata: { 'auto_cancel_on_incoming_explicit' => true }
    )
    touch.mark_automation_provenance!(rule, trigger_message: trigger_message, action_key: 'legacy-index:0')
    newer_message = incoming_message

    cancelled_count = described_class.new(message: newer_message, event_timestamp: newer_message.created_at).perform

    expect(cancelled_count).to eq(1)
    expect(touch.reload).to be_cancelled
    expect(touch.metadata).to include(
      Reminders::IncomingReplyCancellationService::CANCELLED_BY_MESSAGE_ID_KEY => newer_message.id
    )
  end

  it 'does not cancel a touch caused by a newer message when jobs run out of order' do
    older_message = incoming_message
    newer_message = incoming_message
    rule = create(:automation_rule, account: account)
    touch = create(
      :reminder,
      account: account,
      conversation: conversation,
      remindable: conversation,
      status: :pending,
      auto_cancel_on_incoming: true,
      metadata: { 'auto_cancel_on_incoming_explicit' => true }
    )
    touch.mark_automation_provenance!(rule, trigger_message: newer_message, action_key: 'legacy-index:0')

    cancelled_count = described_class.new(message: older_message, event_timestamp: older_message.created_at).perform

    expect(cancelled_count).to eq(0)
    expect(touch.reload).to be_pending
  end

  it 'preserves an untagged touch created after the event timestamp' do
    message = incoming_message
    touch = create(
      :reminder,
      account: account,
      conversation: conversation,
      remindable: conversation,
      status: :pending,
      auto_cancel_on_incoming: true,
      metadata: { 'auto_cancel_on_incoming_explicit' => true }
    )

    cancelled_count = described_class.new(message: message, event_timestamp: message.created_at).perform

    expect(cancelled_count).to eq(0)
    expect(touch.reload).to be_pending
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

  it 'cancels a deferred reminder materialized between the initial scan and enrollment lock' do
    account.enable_features!('deferred_touch_materialization')
    appointment = create(
      :scheduling_appointment,
      account: account,
      contact: contact,
      conversation: conversation,
      starts_at: 1.day.from_now,
      ends_at: 1.day.from_now + 30.minutes
    )
    plan = create(
      :reminder_group,
      account: account,
      touches: [
        {
          body: 'Do not race the reply',
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
    service = described_class.new(message: incoming_message)
    allow(service).to receive(:cancel_materialized_reminders!).and_wrap_original do |method|
      count = method.call
      Reminders::MaterializeEnrollmentStepService.new(enrollment: enrollment).perform
      count
    end

    cancelled_count = service.perform

    reminder = account.reminders.find_by!(remindable: appointment)
    expect(cancelled_count).to eq(1)
    expect(reminder).to be_cancelled
    expect(reminder.last_error).to eq(described_class::CANCELLED_AFTER_INCOMING_REPLY)
    expect(enrollment.reload).to be_completed
  end
end
