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
      processing_started_at: 5.minutes.ago,
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
    it 'cancels draft, pending, and processing touches scoped to the remindable and touch plan' do
      cancelled_count = described_class.new(
        account: account,
        remindable: conversation,
        reminder_group: touch_plan,
        reason: 'Customer replied',
        metadata: { 'automation_rule_id' => 123, 'cancelled_via' => 'automation_cancel_touches' }
      ).perform

      expect(cancelled_count).to eq(3)
      expect(draft_touch.reload).to be_cancelled
      expect(pending_touch.reload).to be_cancelled
      expect(processing_touch.reload).to be_cancelled
      expect(processing_touch.processing_started_at).to be_nil
      expect(draft_touch.cancelled_at).to be_present
      expect(pending_touch.last_error).to eq('Customer replied')
      expect(pending_touch.metadata).to include(
        'automation_rule_id' => 123,
        'cancelled_via' => 'automation_cancel_touches',
        'cancelled_reason' => 'Customer replied'
      )

      expect(completed_touch.reload).to be_completed
      expect(other_plan_touch.reload).to be_pending
      expect(other_conversation_touch.reload).to be_pending
    end

    it 'cancels all open touches for the remindable when no touch plan is supplied' do
      cancelled_count = described_class.new(account: account, remindable: conversation).perform

      expect(cancelled_count).to eq(4)
      expect(draft_touch.reload).to be_cancelled
      expect(pending_touch.reload).to be_cancelled
      expect(other_plan_touch.reload).to be_cancelled
      expect(processing_touch.reload).to be_cancelled
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

  describe '#perform_with_details' do
    it 'returns detailed counts, scoped ids, skipped records, and remaining open touches' do
      result = described_class.new(
        account: account,
        remindable: conversation,
        reminder_group: touch_plan,
        reason: 'Customer replied'
      ).perform_with_details

      expect(result).to include(
        reason: 'Customer replied',
        found_count: 4,
        cancellable_count: 3,
        cancelled_count: 3,
        skipped_count: 1,
        failed_count: 0,
        already_terminal_count: 1,
        remaining_open_count: 0
      )
      expect(result[:cancelled_touch_ids]).to contain_exactly(draft_touch.id, pending_touch.id, processing_touch.id)
      expect(result[:skipped_touches]).to contain_exactly(
        hash_including(touch_id: completed_touch.id, status: 'completed', reason: 'already_completed')
      )
      expect(result[:failures]).to eq([])
      expect(result[:scope]).to include(
        account_id: account.id,
        remindable_type: 'Conversation',
        remindable_id: conversation.id,
        reminder_group_id: touch_plan.id
      )
    end

    it 'continues cancelling and reports individual record failures' do
      pending_touch.update_column(:timezone, 'Invalid/Zone')

      result = described_class.new(
        account: account,
        remindable: conversation,
        reminder_group: touch_plan,
        reason: 'Customer replied'
      ).perform_with_details

      expect(result[:cancelled_count]).to eq(2)
      expect(result[:cancelled_touch_ids]).to contain_exactly(draft_touch.id, processing_touch.id)
      expect(result[:skipped_count]).to eq(1)
      expect(result[:skipped_touches]).to contain_exactly(
        hash_including(touch_id: completed_touch.id, status: 'completed', reason: 'already_completed')
      )
      expect(result[:failed_count]).to eq(1)
      expect(result[:failures]).to contain_exactly(
        hash_including(touch_id: pending_touch.id, status: 'pending')
      )
      expect(result[:remaining_open_count]).to eq(1)
      expect(draft_touch.reload).to be_cancelled
      expect(pending_touch.reload).to be_pending
      expect(processing_touch.reload).to be_cancelled
    end

    it 'cancels legacy conversation-scoped touches without a remindable link' do
      pending_touch.update_columns(remindable_type: nil, remindable_id: nil)
      draft_touch.update_columns(remindable_type: nil, remindable_id: nil, conversation_id: nil)

      result = described_class.new(
        account: account,
        remindable: conversation,
        reminder_group: touch_plan,
        reason: 'Customer replied'
      ).perform_with_details

      expect(result[:cancelled_count]).to eq(3)
      expect(result[:cancelled_touch_ids]).to contain_exactly(draft_touch.id, pending_touch.id, processing_touch.id)
      expect(result[:skipped_touches]).to contain_exactly(
        hash_including(touch_id: completed_touch.id, status: 'completed', reason: 'already_completed')
      )
      expect(pending_touch.reload).to be_cancelled
      expect(draft_touch.reload).to be_cancelled
      expect(processing_touch.reload).to be_cancelled
    end

    it 'returns an empty structured result when no touches match the scope' do
      empty_conversation = create(:conversation, account: account)

      result = described_class.new(account: account, remindable: empty_conversation).perform_with_details

      expect(result).to include(
        found_count: 0,
        cancellable_count: 0,
        cancelled_count: 0,
        skipped_count: 0,
        failed_count: 0,
        already_terminal_count: 0,
        remaining_open_count: 0
      )
      expect(result[:cancelled_touch_ids]).to eq([])
      expect(result[:skipped_touches]).to eq([])
      expect(result[:failures]).to eq([])
    end

    it 'reports already-terminal touches without mutating them on repeat bulk cancel' do
      service = described_class.new(
        account: account,
        remindable: conversation,
        reminder_group: touch_plan,
        reason: 'Stop sequence'
      )
      service.perform_with_details

      result = service.perform_with_details

      expect(result).to include(
        found_count: 4,
        cancellable_count: 0,
        cancelled_count: 0,
        skipped_count: 4,
        failed_count: 0,
        already_terminal_count: 4,
        remaining_open_count: 0
      )
      expect(result[:cancelled_touch_ids]).to eq([])
      expect(result[:skipped_touches]).to include(
        hash_including(touch_id: draft_touch.id, status: 'cancelled', reason: 'already_cancelled'),
        hash_including(touch_id: pending_touch.id, status: 'cancelled', reason: 'already_cancelled'),
        hash_including(touch_id: processing_touch.id, status: 'cancelled', reason: 'already_cancelled'),
        hash_including(touch_id: completed_touch.id, status: 'completed', reason: 'already_completed')
      )
      expect(draft_touch.reload).to be_cancelled
      expect(pending_touch.reload).to be_cancelled
      expect(processing_touch.reload).to be_cancelled
      expect(completed_touch.reload).to be_completed
    end

    it 'does not cancel CRM reminders that are only routed through the conversation' do
      deal = create(:crm_deal, account: account, originating_conversation: conversation)
      create(:crm_deal_contact, account: account, deal: deal, contact: conversation.contact)
      deal_touch = create(
        :reminder,
        account: account,
        remindable: deal,
        touch_conversation: conversation,
        reminder_group: touch_plan,
        status: :pending,
        body: 'Deal follow-up'
      )

      result = described_class.new(account: account, remindable: conversation).perform_with_details

      expect(result[:cancelled_touch_ids]).not_to include(deal_touch.id)
      expect(deal_touch.reload).to be_pending
    end
  end
end
