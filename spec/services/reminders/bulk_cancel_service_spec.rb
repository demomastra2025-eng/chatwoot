require 'rails_helper'

RSpec.describe Reminders::BulkCancelService do
  let(:account) { create(:account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:other_conversation) { create(:conversation, account: account) }
  let(:touch_plan) { create(:reminder_group, account: account, entity_kinds: ['conversation']) }
  let(:other_touch_plan) { create(:reminder_group, account: account, entity_kinds: ['conversation']) }

  let!(:draft_touch) do
    create(
      :reminder,
      :draft,
      account: account,
      touch_conversation: conversation,
      remindable: conversation,
      reminder_group: touch_plan,
      body: 'Draft follow-up'
    )
  end
  let!(:pending_touch) do
    create(
      :reminder,
      account: account,
      touch_conversation: conversation,
      remindable: conversation,
      reminder_group: touch_plan,
      body: 'Pending follow-up'
    )
  end
  let!(:processing_touch) do
    create(
      :reminder,
      account: account,
      touch_conversation: conversation,
      remindable: conversation,
      reminder_group: touch_plan,
      status: 'processing',
      body: 'Processing follow-up'
    )
  end
  let!(:completed_touch) do
    create(
      :reminder,
      account: account,
      touch_conversation: conversation,
      remindable: conversation,
      reminder_group: touch_plan,
      status: 'completed',
      body: 'Completed follow-up'
    )
  end
  let!(:other_plan_touch) do
    create(
      :reminder,
      account: account,
      touch_conversation: conversation,
      remindable: conversation,
      reminder_group: other_touch_plan,
      body: 'Other plan follow-up'
    )
  end
  let!(:other_conversation_touch) do
    create(
      :reminder,
      account: account,
      touch_conversation: other_conversation,
      remindable: other_conversation,
      reminder_group: touch_plan,
      body: 'Other conversation follow-up'
    )
  end

  describe '#perform' do
    it 'cancels only draft and pending touches scoped to the remindable and touch plan' do
      cancelled_count = described_class.new(
        account: account,
        remindable: conversation,
        reminder_group: touch_plan,
        reason: 'Customer replied',
        metadata: { 'automation_rule_id' => 123, 'cancelled_via' => 'automation_cancel_touches' }
      ).perform

      expect(cancelled_count).to eq(2)
      expect(draft_touch.reload).to be_cancelled
      expect(pending_touch.reload).to be_cancelled
      expect(draft_touch.cancelled_at).to be_present
      expect(pending_touch.last_error).to eq('Customer replied')
      expect(pending_touch.metadata).to include(
        'automation_rule_id' => 123,
        'cancelled_via' => 'automation_cancel_touches',
        'cancelled_reason' => 'Customer replied'
      )

      expect(processing_touch.reload).to be_processing
      expect(completed_touch.reload).to be_completed
      expect(other_plan_touch.reload).to be_pending
      expect(other_conversation_touch.reload).to be_pending
    end

    it 'cancels all draft and pending touches for the remindable when no touch plan is supplied' do
      cancelled_count = described_class.new(account: account, remindable: conversation).perform

      expect(cancelled_count).to eq(3)
      expect(draft_touch.reload).to be_cancelled
      expect(pending_touch.reload).to be_cancelled
      expect(other_plan_touch.reload).to be_cancelled
      expect(other_conversation_touch.reload).to be_pending
    end

    it 'rejects remindables outside of the account boundary' do
      other_account = create(:account)
      other_account_conversation = create(:conversation, account: other_account)

      expect do
        described_class.new(account: account, remindable: other_account_conversation).perform
      end.to raise_error(ArgumentError, 'remindable does not belong to account')
    end
  end
end
