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
  end
end
