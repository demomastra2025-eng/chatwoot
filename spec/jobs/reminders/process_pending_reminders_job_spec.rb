require 'rails_helper'

RSpec.describe Reminders::ProcessPendingRemindersJob do
  describe '#perform' do
    it 'moves due touches to processing and enqueues execution' do
      reminder = create(:reminder, scheduled_at: 5.minutes.ago, status: :pending)
      old_claim = reminder.mark_processing!
      reminder.mark_delivery_materialized!(123)
      reminder.update!(status: :pending, processing_started_at: nil)

      expect do
        described_class.perform_now
      end.to have_enqueued_job(Reminders::ExecuteReminderJob).with(reminder.id, kind_of(String)).on_queue('reminders')

      reminder.reload
      expect(reminder).to be_processing
      expect(reminder.processing_started_at).to be_present
      expect(reminder.processing_claim_token).to be_present
      expect(reminder.processing_claim_token).not_to eq(old_claim)
      expect(reminder.metadata['delivery_materialized_message_id']).to be_nil
      payload_metadata = Outbound::PayloadBuilder.touch_payload(reminder).fetch(:metadata)
      expect(payload_metadata.keys & Reminder::INTERNAL_METADATA_KEYS).to be_empty
    end

    it 'ignores future touches' do
      reminder = create(:reminder, scheduled_at: 2.hours.from_now, status: :pending)

      described_class.perform_now

      expect(reminder.reload).to be_pending
    end

    it 'releases all claims that were not enqueued when the queue rejects a job' do
      reminders = create_list(:reminder, 2, scheduled_at: 5.minutes.ago, status: :pending)
      enqueue_error = ActiveJob::EnqueueError.new('Queue unavailable')
      failed_job = instance_double(
        Reminders::ExecuteReminderJob,
        successfully_enqueued?: false,
        enqueue_error: enqueue_error
      )
      allow(Reminders::ExecuteReminderJob).to receive(:perform_later).and_return(failed_job)

      expect do
        described_class.perform_now
      end.to raise_error(ActiveJob::EnqueueError, 'Queue unavailable')

      expect(reminders.map { |reminder| reminder.reload.status }).to eq(%w[pending pending])
      expect(reminders.map(&:processing_claim_token)).to eq([nil, nil])
    end
  end
end
