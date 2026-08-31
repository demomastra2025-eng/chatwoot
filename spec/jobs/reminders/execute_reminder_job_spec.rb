require 'rails_helper'

RSpec.describe Reminders::ExecuteReminderJob do
  describe '#perform' do
    it 'no-ops when a queued job carries an older processing claim' do
      conversation = create(:conversation)
      touch = create(
        :reminder,
        account: conversation.account,
        conversation: conversation,
        remindable: conversation,
        status: :pending,
        body: 'Only the current claim may send'
      )
      current_claim = touch.mark_processing!

      expect do
        described_class.perform_now(touch.id, 'stale-claim')
      end.not_to(change { conversation.messages.outgoing.count })

      expect(touch.reload).to be_processing
      expect(touch.processing_claim_token).to eq(current_claim)
    end

    it 'executes a legacy processing row that predates explicit claim tokens' do
      conversation = create(:conversation)
      touch = create(
        :reminder,
        account: conversation.account,
        conversation: conversation,
        remindable: conversation,
        status: :processing,
        processing_started_at: 1.minute.ago,
        body: 'Legacy queued touch',
        metadata: {}
      )

      expect do
        described_class.perform_now(touch.id)
      end.to change { conversation.messages.outgoing.count }.by(1)

      expect(touch.reload).to be_completed
    end

    it 'retries a transient execution failure with the same processing claim' do
      touch = create(:reminder, status: :pending)
      claim = touch.mark_processing!
      service = instance_double(Reminders::ExecuteService)
      allow(Reminders::ExecuteService).to receive(:new).with(reminder: touch, processing_claim: claim).and_return(service)
      allow(service).to receive(:perform).and_raise(Reminders::RetryableExecutionError, 'provider unavailable')

      expect do
        described_class.perform_now(touch.id, claim)
      end.to have_enqueued_job(described_class).with(touch.id, claim)

      expect(touch.reload).to be_processing
    end

    it 'does not fail a reminder reclaimed while a legacy retry was finishing' do
      touch = create(
        :reminder,
        status: :processing,
        processing_started_at: 1.minute.ago,
        metadata: {}
      )
      service = instance_double(Reminders::ExecuteService)
      allow(Reminders::ExecuteService).to receive(:new).and_return(service)
      allow(service).to receive(:perform) do
        touch.mark_processing!
        raise Reminders::RetryableExecutionError, 'provider unavailable'
      end
      job = described_class.new(touch.id)
      job.executions = 2
      job.exception_executions = { Reminders::RetryableExecutionError.to_s => 2 }

      job.perform_now

      expect(touch.reload).to be_processing
      expect(touch.processing_claim_token).to be_present
    end

    it 'no-ops queued execution when a processing touch was bulk-cancelled before the job ran' do
      conversation = create(:conversation)
      touch = create(
        :reminder,
        account: conversation.account,
        touch_conversation: conversation,
        conversation: conversation,
        remindable: conversation,
        status: :processing,
        processing_started_at: 5.minutes.ago,
        body: 'Do not send after cancellation'
      )

      Reminders::BulkCancelService.new(
        account: conversation.account,
        remindable: conversation,
        reason: 'Stop sequence'
      ).perform

      expect do
        described_class.perform_now(touch.id)
      end.not_to(change { conversation.messages.outgoing.count })

      expect(touch.reload).to be_cancelled
      expect(touch.processing_started_at).to be_nil
    end

    it 'discards an undeliverable target instead of retrying the job' do
      touch = create(:reminder, status: :processing, processing_started_at: 1.minute.ago)
      service = instance_double(Reminders::ExecuteService)
      allow(Reminders::ExecuteService).to receive(:new).and_return(service)
      allow(service).to receive(:perform).and_raise(
        Reminders::UndeliverableTargetError,
        'Touch target is not deliverable for this inbox'
      )

      expect { described_class.perform_now(touch.id) }.not_to raise_error
    end
  end
end
