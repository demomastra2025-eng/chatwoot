require 'rails_helper'

RSpec.describe Captain::Tools::Operations::TouchOperations do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:conversation) { create(:conversation, account: account) }
  let(:operation) { described_class.new(assistant: assistant, conversation: conversation, actor: user) }

  let(:conversation_touch_definition) do
    {
      action_type: 'send_message',
      content_kind: 'free_text',
      text_mode: 'static',
      timing_mode: 'relative',
      relative_anchor: 'conversation.created_at',
      relative_offset_seconds: 3600,
      timezone: 'UTC',
      body: 'Plan follow-up',
      attachments: [],
      template_params: {},
      metadata: {}
    }
  end

  describe '#cancel_touch' do
    it 'cancels a pending touch and records Captain audit metadata' do
      touch = create(:reminder, account: account, remindable: conversation, touch_conversation: conversation, status: :pending)

      result = operation.cancel_touch(touch_id: touch.id, reason: 'Customer opted out')

      expect(result.reload).to be_cancelled
      expect(result.last_error).to eq('Customer opted out')
      expect(result.metadata).to include(
        'touch_source' => 'captain',
        'cancelled_via' => 'captain_cancel_touch',
        'captain_assistant_id' => assistant.id
      )
    end

    it 'uses the Captain cancellation reason when no explicit reason is provided' do
      touch = create(:reminder, account: account, remindable: conversation, touch_conversation: conversation, status: :pending)

      result = operation.cancel_touch(touch_id: touch.id)

      expect(result.reload).to be_cancelled
      expect(result.last_error).to eq('отменен капитаном')
      expect(result.metadata['cancelled_reason']).to eq('отменен капитаном')
    end

    it 'does not cancel a processing touch' do
      touch = create(:reminder, account: account, remindable: conversation, touch_conversation: conversation, status: :processing)

      expect do
        operation.cancel_touch(touch_id: touch.id)
      end.to raise_error(ArgumentError, 'Touch can only be cancelled while draft or pending')

      expect(touch.reload).to be_processing
    end
  end

  describe '#delete_touch' do
    it 'deletes a destroyable touch and returns its payload' do
      touch = create(:reminder, account: account, remindable: conversation, touch_conversation: conversation, status: :cancelled)

      payload = operation.delete_touch(touch_id: touch.id)

      expect(payload).to include(id: touch.id, status: 'cancelled')
      expect(account.reminders.exists?(touch.id)).to be(false)
    end

    it 'does not delete completed touches' do
      touch = create(:reminder, account: account, remindable: conversation, touch_conversation: conversation, status: :completed)

      expect do
        operation.delete_touch(touch_id: touch.id)
      end.to raise_error(ArgumentError, 'Only draft, pending, failed, or cancelled touches can be deleted')

      expect(account.reminders.exists?(touch.id)).to be(true)
    end
  end

  describe '#cancel_touches' do
    it 'bulk cancels non-terminal touches for the current entity with optional touch plan filtering' do
      touch_plan = create(:reminder_group, account: account, entity_kinds: ['conversation'], touches: [conversation_touch_definition])
      other_plan = create(:reminder_group, account: account, entity_kinds: ['conversation'], touches: [conversation_touch_definition])
      pending_touch = create(:reminder, account: account, remindable: conversation, touch_conversation: conversation, reminder_group: touch_plan,
                                        status: :pending, body: 'Pending plan follow-up')
      draft_touch = create(:reminder, :draft, account: account, remindable: conversation, touch_conversation: conversation,
                                              reminder_group: touch_plan, body: 'Draft plan follow-up')
      processing_touch = create(:reminder, account: account, remindable: conversation, touch_conversation: conversation, reminder_group: touch_plan,
                                           status: :processing, processing_started_at: 5.minutes.ago, body: 'Processing plan follow-up')
      completed_touch = create(:reminder, account: account, remindable: conversation, touch_conversation: conversation, reminder_group: touch_plan,
                                          status: :completed, body: 'Completed plan follow-up')
      other_plan_touch = create(:reminder, account: account, remindable: conversation, touch_conversation: conversation, reminder_group: other_plan,
                                           status: :pending, body: 'Other plan follow-up')

      payload = operation.cancel_touches(touch_plan_id: touch_plan.id, reason: 'Stop sequence')

      expect(payload[:found_count]).to eq(4)
      expect(payload[:cancellable_count]).to eq(3)
      expect(payload[:cancelled_count]).to eq(3)
      expect(payload[:cancelled_touch_ids]).to contain_exactly(pending_touch.id, draft_touch.id, processing_touch.id)
      expect(payload[:skipped_count]).to eq(1)
      expect(payload[:skipped_touches]).to contain_exactly(
        hash_including(touch_id: completed_touch.id, status: 'completed', reason: 'already_completed')
      )
      expect(payload[:failed_count]).to eq(0)
      expect(payload[:failures]).to eq([])
      expect(payload[:already_terminal_count]).to eq(1)
      expect(payload[:remaining_open_count]).to eq(0)
      expect(payload[:scope]).to include(
        account_id: account.id,
        remindable_type: 'Conversation',
        remindable_id: conversation.id,
        reminder_group_id: touch_plan.id
      )
      expect(pending_touch.reload).to be_cancelled
      expect(draft_touch.reload).to be_cancelled
      expect(processing_touch.reload).to be_cancelled
      expect(completed_touch.reload).to be_completed
      expect(other_plan_touch.reload).to be_pending
      expect(pending_touch.metadata).to include('cancelled_via' => 'captain_cancel_touches', 'touch_plan_id' => touch_plan.id)
    end

    it 'uses the Captain cancellation reason for bulk cancel when no explicit reason is provided' do
      pending_touch = create(:reminder, account: account, remindable: conversation, touch_conversation: conversation,
                                        status: :pending, body: 'Pending follow-up')

      payload = operation.cancel_touches

      expect(payload[:cancelled_count]).to eq(1)
      expect(pending_touch.reload).to be_cancelled
      expect(pending_touch.last_error).to eq('отменен капитаном')
      expect(pending_touch.metadata['cancelled_reason']).to eq('отменен капитаном')
    end
  end

  describe '#create_touch_plan' do
    it 'creates a reusable touch plan with normalized touch definitions' do
      touch_plan = operation.create_touch_plan(
        name: 'Conversation nurture',
        entity_kinds: ['conversation'],
        touches: [conversation_touch_definition]
      )

      expect(touch_plan).to be_persisted
      expect(touch_plan.creator).to eq(user)
      expect(touch_plan.entity_kinds).to eq(['conversation'])
      expect(touch_plan.touches.first).to include('body' => 'Plan follow-up', 'relative_anchor' => 'conversation.created_at')
    end
  end

  describe '#apply_touch_plan' do
    it 'applies an existing touch plan to the current conversation by name' do
      touch_plan = create(:reminder_group, account: account, name: 'Conversation nurture', entity_kinds: ['conversation'],
                                           touches: [conversation_touch_definition])

      touches = operation.apply_touch_plan(touch_plan_name: 'conversation nurture')

      expect(touches.size).to eq(1)
      expect(touches.first.remindable).to eq(conversation)
      expect(touches.first.reminder_group).to eq(touch_plan)
      expect(touches.first.metadata).to include('touch_source' => 'captain', 'captain_touch_plan_id' => touch_plan.id)
    end
  end

  describe '#archive_touch_plan' do
    it 'soft archives an existing touch plan' do
      touch_plan = create(:reminder_group, account: account, entity_kinds: ['conversation'], touches: [conversation_touch_definition])

      result = operation.archive_touch_plan(touch_plan_id: touch_plan.id)

      expect(result.reload).not_to be_active
      expect(result.archived_at).to be_present
    end
  end
end
