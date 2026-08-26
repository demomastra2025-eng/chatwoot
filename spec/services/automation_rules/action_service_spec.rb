require 'rails_helper'

RSpec.describe AutomationRules::ActionService do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account) }
  let(:conversation) { create(:conversation, account: account) }
  let!(:rule) do
    create(:automation_rule, account: account,
                             actions: [
                               { action_name: 'send_webhook_event', action_params: ['https://example.com'] },
                               { action_name: 'send_message', action_params: { message: 'Hello' } }
                             ])
  end

  describe '#perform' do
    context 'when actions are defined in the rule' do
      it 'will call the actions' do
        expect(Messages::MessageBuilder).to receive(:new)
        expect(WebhookJob).to receive(:perform_later)
        described_class.new(rule, account, conversation).perform
      end
    end

    describe '#perform with send_attachment action' do
      let(:message_builder) { double }

      before do
        allow(Messages::MessageBuilder).to receive(:new).and_return(message_builder)
        rule.actions.delete_if { |a| a['action_name'] == 'send_message' }
        rule.files.attach(io: Rails.root.join('spec/assets/avatar.png').open, filename: 'avatar.png', content_type: 'image/png')
        rule.save!
        rule.actions << { action_name: 'send_attachment', action_params: [rule.files.first.blob_id] }
      end

      it 'will send attachment' do
        expect(message_builder).to receive(:perform)
        described_class.new(rule, account, conversation).perform
      end

      it 'will not send attachment is conversation is a tweet' do
        twitter_inbox = create(:inbox, channel: create(:channel_twitter_profile, account: account))
        conversation = create(:conversation, inbox: twitter_inbox, additional_attributes: { type: 'tweet' })
        expect(message_builder).not_to receive(:perform)
        described_class.new(rule, account, conversation).perform
      end
    end

    describe '#perform with send_webhook_event action' do
      it 'will send webhook event' do
        expect(rule.actions.pluck('action_name')).to include('send_webhook_event')
        expect(WebhookJob).to receive(:perform_later)
        described_class.new(rule, account, conversation).perform
      end
    end

    describe '#perform with send_message action' do
      let(:message_builder) { double }

      before do
        allow(Messages::MessageBuilder).to receive(:new).and_return(message_builder)
      end

      it 'will send message' do
        expect(rule.actions.pluck('action_name')).to include('send_message')
        expect(message_builder).to receive(:perform)
        described_class.new(rule, account, conversation).perform
      end

      it 'will not send message if conversation is a tweet' do
        expect(rule.actions.pluck('action_name')).to include('send_message')
        twitter_inbox = create(:inbox, channel: create(:channel_twitter_profile, account: account))
        conversation = create(:conversation, inbox: twitter_inbox, additional_attributes: { type: 'tweet' })
        expect(message_builder).not_to receive(:perform)
        described_class.new(rule, account, conversation).perform
      end
    end

    describe '#perform with apply_touch_plan action' do
      let(:touch_plan) do
        create(
          :reminder_group,
          account: account,
          entity_kinds: ['conversation'],
          touches: [
            {
              action_type: 'send_message',
              content_kind: 'free_text',
              text_mode: 'static',
              timing_mode: 'relative',
              relative_anchor: 'touch.created_at',
              relative_offset_seconds: 60,
              timezone: 'UTC',
              body: 'Follow up',
              attachments: [],
              template_params: {},
              metadata: {}
            }
          ]
        )
      end

      before do
        rule.actions = [{ action_name: 'apply_touch_plan', action_params: [touch_plan.id] }]
        rule.save!(validate: false)
      end

      it 'creates pending touches from the touch plan for the conversation' do
        expect do
          described_class.new(rule, account, conversation).perform
        end.to change { account.reminders.where(reminder_group: touch_plan, remindable: conversation).count }.by(1)

        touch = account.reminders.where(reminder_group: touch_plan, remindable: conversation).last
        expect(touch).to be_pending
        expect(touch.target_inbox).to eq(conversation.inbox)
        expect(touch.target_contact).to eq(conversation.contact)
        expect(touch.target_conversation).to eq(conversation)
      end

      it 'does not duplicate touch-plan reminders when the Redis completion marker fails' do
        execution_key = "touch-plan-retry-#{SecureRandom.uuid}"
        marker_failed = false
        allow(Redis::Alfred).to receive(:set).and_wrap_original do |method, key, *args, **kwargs|
          unless marker_failed
            marker_failed = true
            raise Redis::BaseError, 'marker write failed'
          end

          method.call(key, *args, **kwargs)
        end

        expect do
          described_class.new(rule, account, conversation, execution_key: execution_key).perform
        end.to raise_error(Redis::BaseError, 'marker write failed')

        expect do
          described_class.new(rule, account, conversation, execution_key: execution_key).perform
        end.not_to(change { account.reminders.where(reminder_group: touch_plan, remindable: conversation).count })

        expect(account.reminders.where(reminder_group: touch_plan, remindable: conversation).count).to eq(1)
      end
    end

    describe '#perform with cancel_touches action' do
      let(:touch_plan) { create(:reminder_group, account: account, entity_kinds: ['conversation']) }

      before do
        rule.actions = [
          {
            action_name: 'cancel_touches',
            action_params: [{ reminder_group_id: touch_plan.id, reason: 'Customer replied' }]
          }
        ]
        rule.save!(validate: false)
      end

      it 'delegates cancellation to the touch action service' do
        touch_action_service = instance_double(AutomationRules::TouchActionService)
        allow(AutomationRules::TouchActionService).to receive(:new).and_return(touch_action_service)
        allow(touch_action_service).to receive(:cancel_touches)

        described_class.new(rule, account, conversation).perform

        expect(touch_action_service).to have_received(:cancel_touches) do |action_params|
          expect(action_params.first).to include(
            'reminder_group_id' => touch_plan.id,
            'reason' => 'Customer replied'
          )
        end
      end
    end

    describe '#perform with multiple create_touch actions' do
      before do
        rule.actions = [
          {
            action_name: 'create_touch',
            action_params: [{ body: 'First automation touch', delay_minutes: 10 }]
          },
          {
            action_name: 'create_touch',
            action_params: [{ body: 'Second automation touch', delay_minutes: 20 }]
          }
        ]
        rule.save!
      end

      it 'creates each touch directly without applying a touch plan' do
        expect do
          described_class.new(rule, account, conversation).perform
        end.to change { account.reminders.where(remindable: conversation).count }.by(2)

        expect(account.reminders.where(remindable: conversation).pluck(:body)).to contain_exactly(
          'First automation touch',
          'Second automation touch'
        )
      end

      it 'does not duplicate a durable touch when the Redis completion marker fails after creation' do
        execution_key = "retry-after-side-effect-#{SecureRandom.uuid}"
        first_action_id = rule.reload.actions.first.fetch('action_id')
        marker_failed = false
        allow(Redis::Alfred).to receive(:set).and_wrap_original do |method, key, *args, **kwargs|
          if key.include?(first_action_id) && !marker_failed
            marker_failed = true
            raise Redis::BaseError, 'marker write failed'
          end

          method.call(key, *args, **kwargs)
        end

        expect do
          described_class.new(rule, account, conversation, execution_key: execution_key).perform
        end.to raise_error(Redis::BaseError, 'marker write failed')

        expect do
          described_class.new(rule, account, conversation, execution_key: execution_key).perform
        end.not_to(change { account.reminders.where(remindable: conversation).count })

        expect(account.reminders.where(remindable: conversation).count).to eq(2)
      end
    end

    describe '#perform with a legacy message-triggered create_touch action' do
      let(:trigger_message) do
        create(
          :message,
          account: account,
          inbox: conversation.inbox,
          conversation: conversation,
          sender: conversation.contact,
          message_type: :incoming,
          private: false
        )
      end
      let(:legacy_action) do
        {
          'action_name' => 'create_touch',
          'action_params' => [{
            'body' => 'Close after inactivity',
            'delay_minutes' => 1380,
            'auto_cancel_on_incoming' => true,
            'post_delivery_action' => 'resolve_conversation'
          }]
        }
      end

      before do
        # Reproduce an action persisted before action IDs were normalized.
        # rubocop:disable Rails/SkipsModelValidations
        rule.update_column(:actions, [legacy_action])
        # rubocop:enable Rails/SkipsModelValidations
      end

      it 'is idempotent, preserves the current touch, and cancels it on the next incoming message' do
        service = described_class.new(rule.reload, account, conversation, trigger_message: trigger_message)

        expect do
          service.perform
          described_class.new(rule.reload, account, conversation, trigger_message: trigger_message).perform
        end.to change { account.reminders.where(remindable: conversation).count }.by(1)

        touch = account.reminders.find_by!(remindable: conversation)
        expect(touch.metadata).to include(
          Reminder::AUTOMATION_TRIGGER_MESSAGE_ID_KEY => trigger_message.id,
          Reminder::AUTOMATION_ACTION_KEY => 'legacy-index:0'
        )

        current_count = Reminders::AutoCancelOnIncomingService.new(
          message: trigger_message,
          event_timestamp: trigger_message.created_at
        ).perform
        expect(current_count).to eq(0)
        expect(touch.reload).to be_pending

        next_message = create(
          :message,
          account: account,
          inbox: conversation.inbox,
          conversation: conversation,
          sender: conversation.contact,
          message_type: :incoming,
          private: false
        )
        next_count = Reminders::AutoCancelOnIncomingService.new(
          message: next_message,
          event_timestamp: next_message.created_at
        ).perform

        expect(next_count).to eq(1)
        expect(touch.reload).to be_cancelled
      end

      it 'cancels a stale touch when a newer incoming message already exists' do
        trigger_message
        newer_message = create(
          :message,
          account: account,
          inbox: conversation.inbox,
          conversation: conversation,
          sender: conversation.contact,
          message_type: :incoming,
          private: false
        )

        described_class.new(rule.reload, account, conversation, trigger_message: trigger_message).perform

        touch = account.reminders.find_by!(remindable: conversation)
        expect(touch).to be_cancelled
        expect(touch.metadata).to include(
          Reminders::IncomingReplyCancellationService::CANCELLED_BY_MESSAGE_ID_KEY => newer_message.id
        )
      end
    end

    describe '#perform with send_email_to_team action' do
      let!(:team) { create(:team, account: account) }

      before do
        rule.actions << { action_name: 'send_email_to_team', action_params: [{ team_ids: [team.id], message: 'Hello' }] }
      end

      it 'will send email to team' do
        expect(TeamNotifications::AutomationNotificationMailer).to receive(:conversation_creation).with(conversation, team, 'Hello').and_call_original
        described_class.new(rule, account, conversation).perform
      end
    end

    describe '#perform with remove assignment actions' do
      let!(:team) { create(:team, account: account) }

      before do
        conversation.update!(assignee: agent, team: team)
        rule.actions = [
          { action_name: 'remove_assigned_agent', action_params: [] },
          { action_name: 'remove_assigned_team', action_params: [] }
        ]
        rule.save!
      end

      it 'removes assignee and team from the conversation' do
        described_class.new(rule, account, conversation).perform

        expect(conversation.reload.assignee).to be_nil
        expect(conversation.team).to be_nil
      end
    end

    describe '#perform with send_email_transcript action' do
      before do
        allow(account).to receive(:email_transcript_enabled?).and_return(true)
        allow(account).to receive(:within_email_rate_limit?).and_return(true)
        allow(account).to receive(:increment_email_sent_count).and_return(true)
        rule.actions << { action_name: 'send_email_transcript', action_params: ['contact@example.com, agent@example.com,agent1@example.com'] }
        rule.save
      end

      it 'will send email to transcript to action params emails' do
        mailer = double
        allow(ConversationReplyMailer).to receive(:with).and_return(mailer)
        allow(mailer).to receive(:conversation_transcript).with(conversation, 'contact@example.com')
        allow(mailer).to receive(:conversation_transcript).with(conversation, 'agent@example.com')
        allow(mailer).to receive(:conversation_transcript).with(conversation, 'agent1@example.com')

        described_class.new(rule, account, conversation).perform
        expect(mailer).to have_received(:conversation_transcript).exactly(3).times
      end

      it 'will send email to transcript to contacts' do
        rule.actions = [{ action_name: 'send_email_transcript', action_params: ['{{contact.email}}'] }]
        rule.save

        mailer = double
        allow(ConversationReplyMailer).to receive(:with).and_return(mailer)
        allow(mailer).to receive(:conversation_transcript).with(conversation, conversation.contact.email)

        described_class.new(rule.reload, account, conversation).perform
        expect(mailer).to have_received(:conversation_transcript).exactly(1).times
      end
    end

    describe '#perform with add_label action' do
      before do
        rule.actions << { action_name: 'add_label', action_params: %w[bug feature] }
        rule.save
      end

      it 'will add labels to conversation' do
        described_class.new(rule, account, conversation).perform
        expect(conversation.reload.label_list).to include('bug', 'feature')
      end

      it 'will not duplicate existing labels' do
        conversation.add_labels(['bug'])
        described_class.new(rule, account, conversation).perform
        expect(conversation.reload.label_list.count('bug')).to eq(1)
        expect(conversation.reload.label_list).to include('feature')
      end
    end

    describe '#perform with remove_label action' do
      before do
        conversation.add_labels(%w[bug feature support])
        rule.actions << { action_name: 'remove_label', action_params: %w[bug feature] }
        rule.save
      end

      it 'will remove specified labels from conversation' do
        described_class.new(rule, account, conversation).perform
        expect(conversation.reload.label_list).not_to include('bug', 'feature')
        expect(conversation.reload.label_list).to include('support')
      end

      it 'will not fail if labels do not exist on conversation' do
        conversation.update_labels(['support']) # Remove bug and feature first
        expect { described_class.new(rule, account, conversation).perform }.not_to raise_error
        expect(conversation.reload.label_list).to include('support')
      end
    end

    describe '#perform with add_private_note action' do
      let(:message_builder) { double }

      before do
        allow(Messages::MessageBuilder).to receive(:new).and_return(message_builder)
        rule.actions.delete_if { |a| a['action_name'] == 'send_message' }
        rule.actions << { action_name: 'add_private_note', action_params: ['Note'] }
      end

      it 'will add private note' do
        expect(message_builder).to receive(:perform)
        described_class.new(rule, account, conversation).perform
      end

      it 'will not add note if conversation is a tweet' do
        twitter_inbox = create(:inbox, channel: create(:channel_twitter_profile, account: account))
        conversation = create(:conversation, inbox: twitter_inbox, additional_attributes: { type: 'tweet' })
        expect(message_builder).not_to receive(:perform)
        described_class.new(rule, account, conversation).perform
      end
    end

    describe '#perform with assign_agent action' do
      before do
        create(:inbox_member, inbox: conversation.inbox, user: agent)
        rule.actions << { action_name: 'assign_agent', action_params: ['last_responding_agent'] }
      end

      it 'assigns the conversation to the last responding agent' do
        create(:message, message_type: :outgoing, account: account,
                         inbox: conversation.inbox, conversation: conversation, sender: agent)

        described_class.new(rule, account, conversation).perform

        expect(conversation.reload.assignee).to eq(agent)
      end
    end
  end
end
