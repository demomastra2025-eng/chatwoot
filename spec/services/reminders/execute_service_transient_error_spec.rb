require 'rails_helper'

# Round-8 P3: a transient database error resets the claim so the touch is retried instead of failing permanently, and
# the retry never duplicates the message.
RSpec.describe Reminders::ExecuteService do
  let(:account) { create(:account) }
  let(:contact) { create(:contact, account: account, phone_number: '+77000000001') }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

  def touch_messages(touch)
    Message.outgoing.where(account_id: account.id).where("additional_attributes ->> 'touch_id' = ?", touch.id.to_s)
  end

  def processing_touch
    create(:reminder, account: account, touch_conversation: conversation, conversation: conversation, remindable: conversation,
                      status: :processing, body: 'Reminder', scheduled_at: 1.minute.ago)
  end

  [ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout, ActiveRecord::SerializationFailure, ActiveRecord::QueryCanceled].each do |error|
    { 'resolving the conversation' => Reminders::ConversationResolver, 'materializing the message' => Reminders::MessageMaterializer }
      .each do |site, klass|
      it "re-claims the touch after #{error.name.demodulize} while #{site} and sends exactly once", :aggregate_failures do
        touch = processing_touch
        raised = false
        allow_any_instance_of(klass).to receive(:perform).and_wrap_original do |original, *args, **kwargs| # rubocop:disable RSpec/AnyInstance
          unless raised
            raised = true
            raise error, 'transient'
          end
          original.call(*args, **kwargs)
        end

        expect { described_class.new(reminder: touch).perform }.not_to raise_error
        expect(touch.reload).to have_attributes(status: 'pending', last_error: nil, processing_started_at: nil)
        expect(touch_messages(touch)).to be_empty

        described_class.new(reminder: touch, processing_claim: touch.mark_processing!).perform

        expect(touch.reload).to be_completed
        expect(touch_messages(touch).count).to eq(1)
      end
    end
  end

  it 'E1 keeps the claim of a materialized touch after a transient error while completing and never sends it twice',
     :aggregate_failures do
    touch = create(:reminder, account: account, touch_conversation: conversation, conversation: conversation, remindable: conversation,
                              status: :pending, body: 'Reminder', scheduled_at: 1.minute.ago)
    claim = touch.mark_processing!
    raised = false
    allow_any_instance_of(Reminders::ExecutionFinisher).to receive(:complete_execution).and_wrap_original do |original, *args| # rubocop:disable RSpec/AnyInstance
      unless raised
        raised = true
        # e.g. the touch row is held by a number transfer past lock_timeout
        raise ActiveRecord::LockWaitTimeout, 'transient'
      end
      original.call(*args)
    end

    expect { described_class.new(reminder: touch, processing_claim: claim).perform }.not_to raise_error
    expect(touch.reload).to have_attributes(status: 'processing', processing_claim_token: claim)
    expect(touch.metadata[Reminder::DELIVERY_MATERIALIZED_MESSAGE_ID_KEY]).to be_present
    expect(Reminders::ExecuteReminderJob).to have_been_enqueued.with(touch.id, claim)
    # The scheduler never re-claims it (a new claim would drop the materialization marker and send again).
    Reminders::ProcessPendingRemindersJob.perform_now
    expect(touch.reload.processing_claim_token).to eq(claim)

    Reminders::ExecuteReminderJob.perform_now(touch.id, claim)

    expect(touch.reload).to be_completed
    expect(touch_messages(touch).count).to eq(1)
  end

  # sc8rv2 round 3 E2T/E3: the delivery job (enqueued before the completion) dispatches the message and consumes the
  # claim before the retried completion runs. The touch must end completed, dispatched exactly once, never stuck in
  # processing.
  context 'when the delivery runs before the retried completion' do
    let(:due_touch) do
      create(:reminder, account: account, touch_conversation: conversation, conversation: conversation, remindable: conversation,
                        status: :pending, body: 'Reminder', scheduled_at: 1.minute.ago)
    end

    before { allow(SendReplyJob).to receive(:perform_now) }

    def fail_completion_once(error)
      raised = false
      allow_any_instance_of(Reminders::ExecutionFinisher).to receive(:complete_execution).and_wrap_original do |original, *args| # rubocop:disable RSpec/AnyInstance
        unless raised
          raised = true
          yield if block_given?
          raise error, 'transient'
        end
        original.call(*args)
      end
    end

    def deliver!(claim) = Reminders::DeliverMaterializedMessageJob.perform_now(due_touch.id, touch_messages(due_touch).sole.id, claim)

    it 'E3 completes the touch when its delivery ran between the failed completion and the retry', :aggregate_failures do
      claim = due_touch.mark_processing!
      fail_completion_once(ActiveRecord::LockWaitTimeout)
      described_class.new(reminder: due_touch, processing_claim: claim).perform

      deliver!(claim)
      expect(due_touch.reload).to have_attributes(status: 'processing', processing_claim_token: nil)
      Reminders::ExecuteReminderJob.perform_now(due_touch.id, claim)

      expect(due_touch.reload).to be_completed
      expect(SendReplyJob).to have_received(:perform_now).once
      expect(touch_messages(due_touch).count).to eq(1)
    end

    it 'E2T completes the touch when its delivery ran while the completion waited, then the completion failed', :aggregate_failures do
      claim = due_touch.mark_processing!
      fail_completion_once(ActiveRecord::QueryCanceled) { deliver!(claim) }

      expect { described_class.new(reminder: due_touch, processing_claim: claim).perform }.not_to raise_error
      expect(Reminders::ExecuteReminderJob).to have_been_enqueued.with(due_touch.id, claim)
      Reminders::ProcessPendingRemindersJob.perform_now
      Reminders::ExecuteReminderJob.perform_now(due_touch.id, claim)

      expect(due_touch.reload).to be_completed
      expect(SendReplyJob).to have_received(:perform_now).once
      expect(touch_messages(due_touch).count).to eq(1)
    end
  end

  it 'C6 releases the claim after a deadlock that left unsaved changes on the touch', :aggregate_failures do
    touch = processing_touch
    raised = false
    allow_any_instance_of(described_class).to receive(:update_resolved_targets!).and_wrap_original do |original, *args| # rubocop:disable RSpec/AnyInstance
      unless raised
        raised = true
        # what a deadlock on the ContactInbox foreign key check of the touch update leaves behind: assigned, unsaved values
        original.receiver.reminder.assign_attributes(target_contact_inbox_id: nil, metadata: touch.metadata.merge('probe' => true))
        raise ActiveRecord::Deadlocked, 'deadlock detected'
      end
      original.call(*args)
    end

    expect { described_class.new(reminder: touch).perform }.not_to raise_error
    expect(touch.reload).to have_attributes(status: 'pending', processing_started_at: nil)
    expect(touch_messages(touch)).to be_empty

    described_class.new(reminder: touch, processing_claim: touch.mark_processing!).perform

    expect(touch.reload).to be_completed
    expect(touch_messages(touch).count).to eq(1)
  end

  it 'still fails a touch permanently on a non-transient error' do
    touch = processing_touch
    allow_any_instance_of(Reminders::ConversationResolver).to receive(:perform).and_raise(ArgumentError, 'broken') # rubocop:disable RSpec/AnyInstance

    expect { described_class.new(reminder: touch).perform }.to raise_error(ArgumentError)
    expect(touch.reload).to have_attributes(status: 'failed', last_error: 'broken')
  end
end
