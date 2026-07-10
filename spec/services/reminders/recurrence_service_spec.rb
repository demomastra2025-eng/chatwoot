require 'rails_helper'

RSpec.describe Reminders::RecurrenceService do
  describe '#schedule_next!' do
    it 'preserves the local wall-clock time across a daylight-saving transition' do
      zone = ActiveSupport::TimeZone['America/New_York']
      scheduled_at = zone.local(2026, 3, 7, 9, 0, 0)
      conversation = create(:conversation)
      reminder = create(
        :reminder,
        account: conversation.account,
        conversation: conversation,
        remindable: conversation,
        status: :pending,
        scheduled_at: scheduled_at,
        timezone: 'America/New_York',
        repeat_mode: :daily,
        repeat_until_at: scheduled_at + 1.month,
        body: 'Daily local-time follow-up',
        metadata: { 'visible' => 'preserved' }
      )
      reminder.mark_processing!
      reminder.mark_delivery_materialized!(123)
      reminder.mark_delivery_dispatched!(123)
      reminder.complete!

      next_touch = described_class.new(reminder: reminder).schedule_next!
      local_next = next_touch.scheduled_at.in_time_zone('America/New_York')

      expect(local_next.strftime('%Y-%m-%d %H:%M %z')).to eq('2026-03-08 09:00 -0400')
      expect(next_touch.timezone).to eq('America/New_York')
      expect(next_touch.metadata).to eq('visible' => 'preserved')
      expect(next_touch).not_to be_delivery_materialized
      expect(next_touch.processing_claim_token).to be_nil
    end
  end
end
