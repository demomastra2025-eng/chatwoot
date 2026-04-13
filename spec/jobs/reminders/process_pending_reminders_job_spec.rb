require 'rails_helper'

RSpec.describe Reminders::ProcessPendingRemindersJob do
  describe '#perform' do
    it 'moves due touches to processing and enqueues execution' do
      reminder = create(:reminder, scheduled_at: 5.minutes.ago, status: :pending)

      expect do
        described_class.perform_now
      end.to have_enqueued_job(Reminders::ExecuteReminderJob).with(reminder.id)

      expect(reminder.reload).to be_processing
      expect(reminder.processing_started_at).to be_present
    end

    it 'ignores future touches' do
      reminder = create(:reminder, scheduled_at: 2.hours.from_now, status: :pending)

      described_class.perform_now

      expect(reminder.reload).to be_pending
    end
  end
end
