require 'rails_helper'

RSpec.describe Reminders::ExecuteReminderJob do
  describe '#perform' do
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
  end
end
