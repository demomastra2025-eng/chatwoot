# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Conversation::FollowUpJob, type: :job do
  let(:account) { create(:account, custom_attributes: { plan_name: 'startups' }) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, status: :pending) }
  let(:steps) do
    Array.new(6) do |index|
      { 'delay_seconds' => 60, 'mode' => 'static', 'message' => "Follow-up #{index + 1}" }
    end
  end
  let(:assistant) do
    create(
      :captain_assistant,
      account: account,
      config: { 'follow_up_settings' => { 'enabled' => true, 'prompt' => '', 'steps' => steps } }
    )
  end
  let(:anchor_message) do
    create(
      :message,
      account: account,
      inbox: inbox,
      conversation: conversation,
      sender: assistant,
      message_type: :outgoing,
      private: false,
      additional_attributes: { captain_ai_reply: { assistant_id: assistant.id } }
    )
  end

  before do
    account.enable_features!('captain_integration', 'captain_tasks')
    create(:captain_inbox, captain_assistant: assistant, inbox: inbox)
    create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming, content: 'Can you help me?')
  end

  def scheduled_step(anchor:, index: 0, conversation_record: conversation, assistant_record: assistant)
    described_class.schedule!(
      conversation: conversation_record,
      assistant: assistant_record,
      anchor_message: anchor,
      step: { index: index, delay_seconds: 60 },
      control_fence: {
        control_generation: conversation_record.current_captain_control_generation,
        status_transition_id: conversation_record.status_transitions.maximum(:id).to_i,
        last_message_id: Captain::Conversation::ControlService.messages_scope(conversation_record).incoming.maximum(:id)
      }
    )
  end

  def evaluator_returns_incomplete
    allow(Captain::ConversationCompletionEvaluator).to receive(:new).and_wrap_original do |original, **attributes|
      evaluator = original.call(**attributes)
      allow(evaluator).to receive(:make_api_call).and_return(
        error: nil,
        message: { 'complete' => false, 'reason' => 'The customer has not answered the latest question' }
      )
      evaluator
    end
  end

  def delivery_for(conversation_record: conversation, assistant_record: assistant)
    lambda do |content, attributes|
      create(
        :message,
        account: conversation_record.account,
        inbox: conversation_record.inbox,
        conversation: conversation_record,
        sender: assistant_record,
        message_type: :outgoing,
        private: false,
        content: content,
        additional_attributes: attributes
      )
    end
  end

  describe '.schedule!' do
    it 'rejects a same-sender public message that is not a Captain AI reply' do
      unmarked = create(
        :message,
        account: account,
        inbox: inbox,
        conversation: conversation,
        sender: assistant,
        message_type: :outgoing,
        private: false
      )

      expect { scheduled_step(anchor: unmarked) }.not_to change(Reminder, :count)
    end

    it 'rejects private and employee-authored anchors' do
      private_anchor = create(
        :message,
        account: account,
        inbox: inbox,
        conversation: conversation,
        sender: assistant,
        message_type: :outgoing,
        private: true,
        additional_attributes: { captain_ai_reply: { assistant_id: assistant.id } }
      )
      employee_anchor = create(
        :message,
        account: account,
        inbox: inbox,
        conversation: conversation,
        sender: create(:user, account: account),
        message_type: :outgoing,
        private: false,
        additional_attributes: { captain_ai_reply: { assistant_id: assistant.id } }
      )

      expect { scheduled_step(anchor: private_anchor) }.not_to change(Reminder, :count)
      expect { scheduled_step(anchor: employee_anchor) }.not_to change(Reminder, :count)

      other_inbox = create(:inbox, account: account)
      create(:captain_inbox, captain_assistant: assistant, inbox: other_inbox)
      mismatched_inbox_anchor = create(
        :message,
        account: account,
        inbox: other_inbox,
        conversation: conversation,
        sender: assistant,
        message_type: :outgoing,
        private: false,
        additional_attributes: { captain_ai_reply: { assistant_id: assistant.id } }
      )
      expect { scheduled_step(anchor: mismatched_inbox_anchor) }.not_to change(Reminder, :count)
    end

    it 'rejects cross-account and internal assistants' do
      other_account = create(:account)
      other_assistant = create(:captain_assistant, account: other_account)
      internal_assistant = create(:captain_assistant, account: account, usage_mode: 'internal_assistant')
      internal_inbox = create(:inbox, account: account)
      internal_conversation = create(:conversation, account: account, inbox: internal_inbox, status: :pending)
      create(:captain_inbox, captain_assistant: internal_assistant, inbox: internal_inbox)
      create(
        :message,
        account: account,
        inbox: internal_inbox,
        conversation: internal_conversation,
        message_type: :incoming,
        content: 'Can you help?'
      )
      internal_anchor = create(
        :message,
        account: account,
        inbox: internal_inbox,
        conversation: internal_conversation,
        sender: internal_assistant,
        message_type: :outgoing,
        private: false,
        additional_attributes: { captain_ai_reply: { assistant_id: internal_assistant.id } }
      )

      expect { scheduled_step(anchor: anchor_message, assistant_record: other_assistant) }.not_to change(Reminder, :count)
      expect do
        scheduled_step(
          anchor: internal_anchor,
          conversation_record: internal_conversation,
          assistant_record: internal_assistant
        )
      end.not_to change(Reminder, :count)
    end

    it 'rejects a reminder whose tenant differs from its assistant, conversation, and anchor' do
      foreign_account = create(:account)
      foreign_inbox = create(:inbox, account: foreign_account)
      foreign_conversation = create(:conversation, account: foreign_account, inbox: foreign_inbox, status: :open)
      foreign_assistant = create(:captain_assistant, account: foreign_account)
      create(:captain_inbox, captain_assistant: foreign_assistant, inbox: foreign_inbox)
      foreign_anchor = create(
        :message,
        account: foreign_account,
        inbox: foreign_inbox,
        conversation: foreign_conversation,
        sender: foreign_assistant,
        message_type: :outgoing,
        private: false,
        additional_attributes: { captain_ai_reply: { assistant_id: foreign_assistant.id } }
      )
      reminder = Reminder.new(
        account: account,
        conversation: foreign_conversation,
        target_conversation: foreign_conversation,
        action_type: :captain_follow_up,
        status: :pending,
        auto_cancel_on_incoming: true,
        scheduled_at: 1.hour.from_now,
        idempotency_key: "captain_follow_up:#{foreign_assistant.id}:#{foreign_anchor.id}:0",
        metadata: {
          'auto_cancel_on_incoming_explicit' => true,
          'captain_follow_up' => {
            'assistant_id' => foreign_assistant.id,
            'anchor_message_id' => foreign_anchor.id,
            'step_index' => 0
          }
        }
      )
      reminder.internal_captain_follow_up_write = true

      expect(reminder).not_to be_valid
      expect(reminder.errors[:account]).not_to be_empty
    end

    it 'maps an unfenced legacy schedule only while its original AI control epoch is still current' do
      reminder = scheduled_step(anchor: anchor_message)
      legacy_metadata = reminder.metadata.to_h.deep_dup
      legacy_metadata['captain_follow_up'].delete('control_fence')
      reminder.update_column(:metadata, legacy_metadata) # rubocop:disable Rails/SkipsModelValidations

      expect(Captain::Conversation::FollowUpGuard.current?(
               reminder: reminder,
               conversation: conversation,
               assistant: assistant,
               anchor_message: anchor_message
             )).to be(true)

      conversation.activate_captain_human_control!(source: 'manual', actor: create(:user, account: account))
      expect(Captain::Conversation::FollowUpGuard.current?(
               reminder: reminder,
               conversation: conversation,
               assistant: assistant,
               anchor_message: anchor_message
             )).to be(false)
    end

    it 'rejects a stale unfenced legacy reminder with no incoming message without raising' do
      reminder = scheduled_step(anchor: anchor_message)
      legacy_metadata = reminder.metadata.to_h.deep_dup
      legacy_metadata['captain_follow_up'].delete('control_fence')
      reminder.update_column(:metadata, legacy_metadata) # rubocop:disable Rails/SkipsModelValidations
      conversation.messages.incoming.delete_all
      owner = conversation.captain_control_owner
      owner.update!(captain_control_generation: owner.captain_control_generation.to_i + 1)

      expect(Captain::Conversation::FollowUpGuard.current?(
               reminder: reminder,
               conversation: conversation,
               assistant: assistant,
               anchor_message: anchor_message
             )).to be(false)
    end

    it 'blocks a new AI chain while a legacy delivery is queued but not provider-submitted' do
      group = create(
        :reminder_group,
        account: account,
        entity_kinds: ['conversation'],
        touches: [{
          action_type: 'send_message',
          content_kind: 'free_text',
          text_mode: 'static',
          timing_mode: 'absolute',
          scheduled_at: 1.day.from_now.iso8601,
          timezone: 'UTC',
          body: 'Legacy conversation plan',
          attachments: [],
          template_params: {},
          metadata: {}
        }]
      )
      legacy_reminder = Reminders::ApplyGroupService.new(
        account: account,
        reminder_group: group,
        remindable: conversation,
        actor: create(:user, account: account, role: :administrator)
      ).perform.sole
      legacy_reminder.update!(status: :completed, completed_at: Time.current)
      materialized_message = create(
        :message,
        account: account,
        inbox: inbox,
        conversation: conversation,
        message_type: :outgoing,
        skip_send_reply: true,
        additional_attributes: { 'touch_id' => legacy_reminder.id, 'touch_source' => 'touch' }
      )
      legacy_reminder.mark_delivery_materialized!(materialized_message.id)

      expect do
        Reminders::DeliverMaterializedMessageJob.perform_later(
          legacy_reminder.id,
          materialized_message.id,
          legacy_reminder.processing_claim_token
        )
      end.to have_enqueued_job(Reminders::DeliverMaterializedMessageJob)
      expect { scheduled_step(anchor: anchor_message) }.not_to(change { account.reminders.captain_follow_up.count })
    end

    it 'blocks a legacy TouchPlan while a materialized AI retry is queued' do
      ai_reminder = scheduled_step(anchor: anchor_message)
      materialized_message = create(
        :message,
        account: account,
        inbox: inbox,
        conversation: conversation,
        sender: assistant,
        message_type: :outgoing,
        private: false,
        skip_send_reply: true,
        additional_attributes: {
          'touch_id' => ai_reminder.id,
          'captain_follow_up' => {
            'assistant_id' => assistant.id,
            'anchor_message_id' => anchor_message.id,
            'step_index' => 0
          }
        }
      )
      ai_reminder.mark_delivery_materialized!(materialized_message.id)
      ai_reminder.mark_delivery_dispatched!(materialized_message.id, stage: 'retry_scheduled')
      group = create(
        :reminder_group,
        account: account,
        entity_kinds: ['conversation'],
        touches: [{
          action_type: 'send_message',
          content_kind: 'free_text',
          text_mode: 'static',
          timing_mode: 'absolute',
          scheduled_at: 1.day.from_now.iso8601,
          timezone: 'UTC',
          body: 'Legacy conversation plan',
          attachments: [],
          template_params: {},
          metadata: {}
        }]
      )

      expect do
        Reminders::ApplyGroupService.new(
          account: account,
          reminder_group: group,
          remindable: conversation,
          actor: create(:user, account: account, role: :administrator)
        ).perform
      end.to raise_error(ArgumentError, 'An AI follow-up chain is already active for this conversation')
    end

    it 'does not overlap with an active legacy TouchPlan' do
      group = create(
        :reminder_group,
        account: account,
        entity_kinds: ['conversation'],
        touches: [
          {
            action_type: 'send_message',
            content_kind: 'free_text',
            text_mode: 'static',
            timing_mode: 'absolute',
            scheduled_at: 1.day.from_now.iso8601,
            timezone: 'UTC',
            body: 'Legacy conversation plan',
            attachments: [],
            template_params: {},
            metadata: {}
          }
        ]
      )
      Reminders::ApplyGroupService.new(
        account: account,
        reminder_group: group,
        remindable: conversation,
        actor: create(:user, account: account, role: :administrator)
      ).perform

      expect { scheduled_step(anchor: anchor_message) }.not_to change(Reminder, :count)
    end
  end

  describe '#perform_for_reminder' do
    it 'saves and executes every configured step in a chain longer than five steps idempotently' do
      evaluator_returns_incomplete
      reminder = scheduled_step(anchor: anchor_message)
      delivery = delivery_for
      sent_messages = []

      6.times do |index|
        message = described_class.new.perform_for_reminder(
          reminder: reminder,
          conversation: conversation,
          assistant: assistant,
          anchor_message: index.zero? ? anchor_message : sent_messages.last,
          delivery: lambda { |content, attributes|
            delivered = delivery.call(content, attributes)
            sent_messages << delivered
            delivered
          }
        )

        expect(message.content).to eq("Follow-up #{index + 1}")
        retry_result = described_class.new.perform_for_reminder(
          reminder: reminder,
          conversation: conversation,
          assistant: assistant,
          anchor_message: index.zero? ? anchor_message : sent_messages[-2],
          delivery: delivery
        )
        expect(retry_result).to eq(message)

        next unless index < 5

        described_class.schedule_after_delivery!(reminder: reminder, message: message)
        reminder = account.reminders.find_by!(
          idempotency_key: "captain_follow_up:#{assistant.id}:#{message.id}:#{index + 1}"
        )
        expect(reminder).to be_pending
      end

      expect(sent_messages.size).to eq(6)
      expect(account.reminders.captain_follow_up.count).to eq(6)
    end

    it 'ends the chain safely when the real completion evaluator cannot evaluate' do
      reminder = scheduled_step(anchor: anchor_message)
      allow(Captain::ConversationCompletionEvaluator).to receive(:new).and_wrap_original do |original, **attributes|
        evaluator = original.call(**attributes)
        allow(evaluator).to receive(:make_api_call).and_return(error: 'provider unavailable', message: nil)
        evaluator
      end

      result = described_class.new.perform_for_reminder(
        reminder: reminder,
        conversation: conversation,
        assistant: assistant,
        anchor_message: anchor_message,
        delivery: delivery_for
      )

      expect(result).to eq(:skipped)
      expect(conversation.messages.outgoing.where("additional_attributes ->> 'touch_id' = ?", reminder.id.to_s)).to be_empty
      expect(Captain::FollowUpAttempt.where(
               account: account,
               assistant: assistant,
               conversation: conversation,
               anchor_message: anchor_message,
               step_index: 0
             ).sole).to be_completed
    end

    it 'does not accept a materialized message from a different conversation' do
      reminder = scheduled_step(anchor: anchor_message)
      other_conversation = create(:conversation, account: account, inbox: inbox, status: :open)
      mismatched_delivery = create(
        :message,
        account: account,
        inbox: inbox,
        conversation: other_conversation,
        sender: assistant,
        message_type: :outgoing,
        private: false,
        content: 'Wrong conversation',
        additional_attributes: {
          captain_follow_up: {
            assistant_id: assistant.id,
            anchor_message_id: anchor_message.id,
            step_index: 0
          }
        }
      )

      expect(
        described_class.new.perform_for_reminder(
          reminder: reminder,
          conversation: conversation,
          assistant: assistant,
          anchor_message: anchor_message,
          delivery: ->(_content, _attributes) { mismatched_delivery }
        )
      ).to eq(:skipped)
    end

    it 'reuses generated content after a transient materialization failure' do
      assistant.update!(
        config: {
          'follow_up_settings' => {
            'enabled' => true,
            'prompt' => 'Be helpful and concise.',
            'steps' => [{ 'delay_seconds' => 60, 'mode' => 'ai', 'objective' => 'Answer the remaining question.' }]
          }
        }
      )
      evaluator_returns_incomplete
      generator = instance_double(Captain::FollowUpMessageGenerator, perform: { generated: true, message: 'Cached follow-up' })
      allow(Captain::FollowUpMessageGenerator).to receive(:new).and_return(generator)
      reminder = scheduled_step(anchor: anchor_message)
      failing_delivery = ->(_content, _attributes) { raise Reminders::RetryableExecutionError, 'temporary database issue' }

      expect do
        described_class.new.perform_for_reminder(
          reminder: reminder,
          conversation: conversation,
          assistant: assistant,
          anchor_message: anchor_message,
          delivery: failing_delivery
        )
      end.to raise_error(Reminders::RetryableExecutionError)

      expect do
        described_class.new.perform_for_reminder(
          reminder: reminder,
          conversation: conversation,
          assistant: assistant,
          anchor_message: anchor_message,
          delivery: delivery_for
        )
      end.to change { conversation.messages.outgoing.count }.by(1)

      expect(generator).to have_received(:perform).once
      expect(conversation.messages.outgoing.last.content).to eq('Cached follow-up')
    end

    it 'stops on a later customer or public employee reply' do
      evaluator_returns_incomplete
      reminder = scheduled_step(anchor: anchor_message)
      delivery = delivery_for
      create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming)

      expect(
        described_class.new.perform_for_reminder(
          reminder: reminder,
          conversation: conversation,
          assistant: assistant,
          anchor_message: anchor_message,
          delivery: delivery
        )
      ).to eq(:skipped)

      employee_anchor = create(
        :message,
        account: account,
        inbox: inbox,
        conversation: conversation,
        sender: assistant,
        message_type: :outgoing,
        private: false,
        additional_attributes: { captain_ai_reply: { assistant_id: assistant.id } }
      )
      create(
        :message,
        account: account,
        inbox: inbox,
        conversation: conversation,
        sender: create(:user, account: account),
        message_type: :outgoing,
        private: false
      )
      expect { scheduled_step(anchor: employee_anchor, index: 0) }.not_to change(Reminder, :count)
    end

    it 'allows terminal reminder state after its conversation closes' do
      reminder = scheduled_step(anchor: anchor_message)
      conversation.update_column(:status, Conversation.statuses[:resolved]) # rubocop:disable Rails/SkipsModelValidations

      expect do
        reminder.update!(status: :completed, completed_at: Time.current)
      end.not_to raise_error

      expect(reminder.reload).to be_completed
    end

    it 'cancels the chain across close and reopen status epochs' do
      reminder = scheduled_step(anchor: anchor_message)

      Conversations::StatusTransitionService.new(
        conversation: conversation,
        params: { status: 'resolved' },
        source: 'system'
      ).perform
      expect(reminder.reload).to be_cancelled

      Conversations::StatusTransitionService.new(
        conversation: conversation,
        params: { status: 'pending' },
        source: 'system'
      ).perform
      expect(Captain::Conversation::FollowUpGuard.current?(
               reminder: reminder,
               conversation: conversation,
               assistant: assistant,
               anchor_message: anchor_message
             )).to be(false)
    end

    it 'stops when the conversation closes or follow-up settings are disabled' do
      reminder = scheduled_step(anchor: anchor_message)
      conversation.update_column(:status, Conversation.statuses[:resolved]) # rubocop:disable Rails/SkipsModelValidations

      expect(
        described_class.new.perform_for_reminder(
          reminder: reminder,
          conversation: conversation,
          assistant: assistant,
          anchor_message: anchor_message,
          delivery: delivery_for
        )
      ).to eq(:skipped)

      conversation.update_column(:status, Conversation.statuses[:pending]) # rubocop:disable Rails/SkipsModelValidations
      assistant.update!(
        config: assistant.config.to_h.deep_stringify_keys.deep_merge(
          'follow_up_settings' => { 'enabled' => false }
        )
      )
      expect { scheduled_step(anchor: anchor_message) }.not_to change(Reminder, :count)
    end
  end
end
