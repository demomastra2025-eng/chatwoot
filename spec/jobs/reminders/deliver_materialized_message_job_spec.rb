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

  def materialized_captain_follow_up
    records = captain_follow_up_records
    claim = records[:reminder].mark_processing!
    message = materialize_follow_up_message(records)
    records[:reminder].update!(status: :completed, completed_at: Time.current)

    [records[:account], records[:conversation], records[:assistant], records[:reminder], claim, message]
  end

  def captain_follow_up_records
    account = create(:account)
    account.enable_features!('captain_integration')
    inbox = create(:inbox, account: account)
    conversation = create(:conversation, account: account, inbox: inbox, status: :pending)
    assistant = create(:captain_assistant, account: account, config: follow_up_config)
    create(:captain_inbox, captain_assistant: assistant, inbox: inbox)
    incoming = create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming, content: 'Please help.')
    anchor = captain_ai_anchor(account, inbox, conversation, assistant)
    fence = {
      control_generation: conversation.current_captain_control_generation,
      status_transition_id: conversation.status_transitions.maximum(:id).to_i,
      last_message_id: incoming.id
    }
    reminder = scheduled_captain_reminder(conversation, assistant, anchor, fence)
    { account: account, conversation: conversation, assistant: assistant, reminder: reminder, anchor: anchor, fence: fence }
  end

  def scheduled_captain_reminder(conversation, assistant, anchor, fence)
    Captain::Conversation::FollowUpJob.schedule!(
      conversation: conversation,
      assistant: assistant,
      anchor_message: anchor,
      step: { index: 0, delay_seconds: 60 },
      control_fence: fence
    )
  end

  def follow_up_config
    {
      'follow_up_settings' => {
        'enabled' => true,
        'prompt' => '',
        'steps' => [
          { 'mode' => 'static', 'message' => 'Checking in.', 'delay_seconds' => 60 },
          { 'mode' => 'static', 'message' => 'One more thought.', 'delay_seconds' => 120 }
        ]
      }
    }
  end

  def captain_ai_anchor(account, inbox, conversation, assistant)
    create(
      :message,
      account: account,
      inbox: inbox,
      conversation: conversation,
      sender: assistant,
      message_type: :outgoing,
      private: false,
      additional_attributes: { captain_ai_reply: { assistant_id: assistant.id } }
    )
  end

  def materialize_follow_up_message(records)
    marker = {
      'captain_follow_up' => {
        'assistant_id' => records[:assistant].id,
        'anchor_message_id' => records[:anchor].id,
        'step_index' => 0,
        'control_fence' => records[:fence]
      }
    }
    Reminders::MessageMaterializer.new(reminder: records[:reminder], additional_attributes: marker).perform(
      conversation: records[:conversation],
      sender: records[:assistant],
      content: 'Checking in.',
      delivery_policy: nil
    )
  end

  it 'schedules the next chain step only after confirmed provider dispatch and keeps retries idempotent' do
    _account, conversation, assistant, reminder, claim, message = materialized_captain_follow_up
    allow(SendReplyJob).to receive(:perform_now_with_follow_up_finalizer) do |_message_id, &finalizer|
      finalizer.call
    end

    2.times { described_class.perform_now(reminder.id, message.id, claim) }

    expect(SendReplyJob).to have_received(:perform_now_with_follow_up_finalizer).with(message.id).once
    next_step = conversation.account.reminders.captain_follow_up.find_by!(
      idempotency_key: "captain_follow_up:#{assistant.id}:#{message.id}:1"
    )
    expect(next_step).to be_pending
    expect(conversation.account.reminders.captain_follow_up.count).to eq(2)
  end

  it 'retries next-step scheduling after provider acceptance without sending twice' do
    _account, conversation, assistant, reminder, claim, message = materialized_captain_follow_up
    allow(SendReplyJob).to receive(:perform_now_with_follow_up_finalizer) do |_message_id, &finalizer|
      finalizer.call
    end
    attempts = 0
    allow(Captain::Conversation::FollowUpJob).to receive(:schedule_after_delivery!).and_wrap_original do |original, **arguments|
      attempts += 1
      raise ActiveRecord::Deadlocked if attempts == 1

      original.call(**arguments)
    end

    expect do
      described_class.perform_now(reminder.id, message.id, claim)
    end.to have_enqueued_job(described_class).with(reminder.id, message.id, claim)

    described_class.perform_now(reminder.id, message.id, claim)

    expect(SendReplyJob).to have_received(:perform_now_with_follow_up_finalizer).with(message.id).once
    next_step = conversation.account.reminders.captain_follow_up.find_by!(
      idempotency_key: "captain_follow_up:#{assistant.id}:#{message.id}:1"
    )
    expect(next_step).to be_pending
  end

  it 'cancels a materialized chain when its assistant is deleted before delivery' do
    account, conversation, assistant, reminder, claim, message = materialized_captain_follow_up
    patient_reminder = create(
      :reminder,
      account: account,
      conversation: conversation,
      remindable: conversation,
      status: :pending,
      body: 'Existing patient reminder'
    )
    assistant.destroy!
    allow(SendReplyJob).to receive(:perform_now_with_follow_up_finalizer)

    described_class.perform_now(reminder.id, message.id, claim)

    expect(SendReplyJob).not_to have_received(:perform_now_with_follow_up_finalizer)
    expect(reminder.reload).to be_cancelled
    expect(reminder).to be_captain_follow_up_delivery_suppressed
    expect(message.reload).to be_failed
    expect(account.reminders.captain_follow_up.active_delivery_or_open).not_to exist
    expect(patient_reminder.reload).to be_pending
  end

  it 'suppresses a queued follow-up after human control takes over' do
    _account, conversation, _assistant, reminder, claim, message = materialized_captain_follow_up
    allow(SendReplyJob).to receive(:perform_now_with_follow_up_finalizer)
    user = create(:user, account: conversation.account)
    conversation.activate_captain_human_control!(source: 'manual', actor: user)

    described_class.perform_now(reminder.id, message.id, claim)

    expect(SendReplyJob).not_to have_received(:perform_now_with_follow_up_finalizer)
    expect(reminder.reload).to be_cancelled
    expect(reminder).to be_captain_follow_up_delivery_suppressed
    expect(message.reload).to be_failed
    expect(reminder.account.reminders.captain_follow_up.count).to eq(1)
  end

  it 'rechecks control at the final send boundary when takeover happens after preparation' do
    _account, conversation, _assistant, reminder, claim, message = materialized_captain_follow_up
    provider = instance_double(Messages::SendEmailNotificationService, perform: true)
    allow(Messages::SendEmailNotificationService).to receive(:new).and_return(provider)
    allow(SendReplyJob).to receive(:perform_now_with_follow_up_finalizer) do |message_id|
      conversation.activate_captain_human_control!(
        source: 'manual',
        actor: create(:user, account: conversation.account)
      )
      SendReplyJob.new.perform(message_id)
    end

    described_class.perform_now(reminder.id, message.id, claim)

    expect(provider).not_to have_received(:perform)
    expect(reminder.reload).to be_cancelled
    expect(reminder).to be_captain_follow_up_delivery_suppressed
    expect(message.reload).to be_failed
  end

  it 'suppresses a queued follow-up after the Captain feature is disabled' do
    account, _conversation, _assistant, reminder, claim, message = materialized_captain_follow_up
    allow(SendReplyJob).to receive(:perform_now_with_follow_up_finalizer)
    account.disable_features!('captain_integration')

    described_class.perform_now(reminder.id, message.id, claim)

    expect(SendReplyJob).not_to have_received(:perform_now_with_follow_up_finalizer)
    expect(reminder.reload).to be_cancelled
    expect(reminder).to be_captain_follow_up_delivery_suppressed
    expect(reminder.account.reminders.captain_follow_up.count).to eq(1)
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
    expect(touch.delivery_stage).to eq('failed')
    expect(touch.metadata[Reminder::DELIVERY_FAILURE_CATEGORY_KEY]).to eq('failed')
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
    expect(touch.delivery_stage).to eq('failed')
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
