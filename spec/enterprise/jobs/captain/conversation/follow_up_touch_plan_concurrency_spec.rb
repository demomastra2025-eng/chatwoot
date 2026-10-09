# frozen_string_literal: true

require 'rails_helper'
require 'timeout'

RSpec.describe 'Captain follow-up and TouchPlan scheduling', type: :job do
  self.use_transactional_tests = false

  after { CommittedRowsCleanup.truncate! }

  it 'serializes a concurrent TouchPlan insertion against the AI follow-up chain' do
    context = create_race_context
    queues = { locked: Queue.new, release: Queue.new, started: Queue.new, results: Queue.new }
    ai_worker = start_ai_scheduler(context, queues)
    group_worker = nil

    Timeout.timeout(5) { queues[:locked].pop }
    group_worker = start_touch_plan_scheduler(context, queues)
    Timeout.timeout(5) { queues[:started].pop }
    sleep 0.1
    queues[:release] << true
    [ai_worker, group_worker].each { |worker| Timeout.timeout(10) { worker.join } }

    outcomes = Array.new(2) { queues[:results].pop }.to_h
    expect(outcomes[:ai]).to be_present
    expect(outcomes[:touch_plan_error]).to be_a(ArgumentError)
    expect(context[:account].reminders.captain_follow_up.open_statuses.count).to eq(1)
    expect(context[:account].reminders.where(reminder_group_id: context[:group].id).open_statuses.count).to eq(0)
  ensure
    queues[:release] << true if queues && queues[:release].empty?
    ai_worker&.join
    group_worker&.join
  end

  def create_race_context
    account = create(:account)
    account.enable_features!('captain_integration')
    ai_context = create_ai_schedule_context(account)
    group = create(:reminder_group, account: account, entity_kinds: ['conversation'], touches: [touch_definition])
    actor = create(:user, account: account, role: :administrator)

    ai_context.merge(account: account, group: group, actor: actor)
  end

  def create_ai_schedule_context(account)
    inbox = create(:inbox, account: account)
    conversation = create(:conversation, account: account, inbox: inbox, status: :pending)
    assistant = create(:captain_assistant, account: account, config: follow_up_config)
    create(:captain_inbox, captain_assistant: assistant, inbox: inbox)
    incoming = create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming, content: 'Hello')
    anchor = create_ai_anchor(account, inbox, conversation, assistant)
    { conversation: conversation, assistant: assistant, anchor: anchor, incoming: incoming }
  end

  def follow_up_config
    { 'follow_up_settings' => { 'enabled' => true, 'prompt' => '', 'steps' => [static_step] } }
  end

  def create_ai_anchor(account, inbox, conversation, assistant)
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

  def static_step
    { 'mode' => 'static', 'message' => 'Checking in.', 'delay_seconds' => 60 }
  end

  def touch_definition
    {
      action_type: 'send_message',
      content_kind: 'free_text',
      text_mode: 'static',
      timing_mode: 'absolute',
      scheduled_at: 1.day.from_now.iso8601,
      timezone: 'UTC',
      body: 'TouchPlan reminder',
      attachments: [],
      template_params: {},
      metadata: {}
    }
  end

  def start_ai_scheduler(context, queues)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        conversation = Conversation.find(context[:conversation].id)
        conversation.with_lock do
          queues[:locked] << true
          Timeout.timeout(5) { queues[:release].pop }
          reminder = schedule_race_ai_follow_up(conversation, context)
          queues[:results] << [:ai, reminder&.id]
        end
      end
    rescue StandardError => e
      queues[:results] << [:ai_error, e]
    end
  end

  def schedule_race_ai_follow_up(conversation, context)
    Captain::Conversation::FollowUpJob.schedule!(
      conversation: conversation,
      assistant: Captain::Assistant.find(context[:assistant].id),
      anchor_message: Message.find(context[:anchor].id),
      step: { index: 0, delay_seconds: 60 },
      control_fence: control_fence(conversation, context[:incoming])
    )
  end

  def start_touch_plan_scheduler(context, queues)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        queues[:started] << true
        result = apply_touch_plan(context)
        queues[:results] << [:touch_plan, result.map(&:id)]
      rescue ArgumentError => e
        queues[:results] << [:touch_plan_error, e]
      end
    end
  end

  def apply_touch_plan(context)
    Reminders::ApplyGroupService.new(
      account: Account.find(context[:account].id),
      reminder_group: ReminderGroup.find(context[:group].id),
      remindable: Conversation.find(context[:conversation].id),
      actor: User.find(context[:actor].id)
    ).perform
  end

  def control_fence(conversation, incoming)
    {
      control_generation: conversation.current_captain_control_generation,
      status_transition_id: conversation.status_transitions.maximum(:id).to_i,
      last_message_id: incoming.id
    }
  end
end
