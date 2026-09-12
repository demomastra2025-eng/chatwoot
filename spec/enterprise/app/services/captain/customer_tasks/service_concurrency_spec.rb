require 'rails_helper'
require 'timeout'

RSpec.describe Captain::CustomerTasks::Service do
  self.use_transactional_tests = false

  it 'returns one task from two PostgreSQL connections racing with the same create key', :aggregate_failures do
    records = create_race_records
    account = records.fetch(:account)
    assistant = records.fetch(:assistant)
    conversation = records.fetch(:conversation)
    task_type = records.fetch(:task_type)
    insert_barrier = Concurrent::CyclicBarrier.new(2)
    results = Concurrent::Array.new
    errors = Concurrent::Array.new
    connection_ids = Concurrent::Array.new
    insert_attempts = Concurrent::Array.new
    default_plan_runs = Concurrent::Array.new
    insert_subscription = subscribe_to_task_inserts(insert_barrier, insert_attempts)
    track_default_plan_runs(default_plan_runs)
    threads = Array.new(2) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          connection_ids << connection.object_id
          thread_assistant = assistant.class.find(assistant.id)
          thread_conversation = conversation.class.find(conversation.id)
          results << described_class.new(
            assistant: thread_assistant,
            conversation: thread_conversation
          ).call(
            action: 'create',
            title: 'Concurrent task',
            task_type: task_type.code,
            idempotency_key: 'customer-task-two-connections-1'
          )
        end
      rescue StandardError => e
        errors << e
      end
    end

    Timeout.timeout(30) { threads.each(&:join) }

    expect(connection_ids.uniq.size).to eq(2)
    expect(insert_attempts.size).to eq(2)
    expect(errors).to be_empty
    expect(results.size).to eq(2)
    expect(results.map { |result| result.dig(:task, :id) }.uniq.size).to eq(1)
    expect(account.crm_tasks.where(idempotency_key: 'customer-task-two-connections-1').count).to eq(1)
    task = account.crm_tasks.find_by!(idempotency_key: 'customer-task-two-connections-1')
    expect(task.events.where(event_type: 'task_created', command_key: 'customer-task-two-connections-1').count).to eq(1)
    expect(Notification.where(primary_actor: task, notification_type: 'task_assignment').count).to eq(1)
    expect(default_plan_runs.size).to eq(1)
  ensure
    threads&.each { |thread| thread.kill if thread.alive? }
    ActiveSupport::Notifications.unsubscribe(insert_subscription) if insert_subscription
    cleanup_task_side_effects(account)
    CommunicationThreadConversation.where(account_id: account&.id).delete_all if account
    CommunicationThread.where(account_id: account&.id).delete_all if account
  end

  def create_race_records
    account = create(:account)
    assistant = create(:captain_assistant, account: account)
    contact = create(:contact, account: account)
    conversation = create(:conversation, account: account, contact: contact)
    create_thread_link(account: account, contact: contact, conversation: conversation)
    account.enable_features!('crm_tasks')
    Crm::Bootstrap::AccountService.new(account: account).perform
    task_type = create_routed_task_type(account)
    { account: account, assistant: assistant, conversation: conversation, task_type: task_type }
  end

  def create_thread_link(account:, contact:, conversation:)
    communication_thread = create(:communication_thread, account: account, contact: contact)
    create(
      :communication_thread_conversation,
      communication_thread: communication_thread,
      conversation: conversation,
      primary: true
    )
  end

  def create_routed_task_type(account)
    assignee = create(:user)
    create(:account_user, account: account, user: assignee)
    team = create(:team, account: account)
    create(:team_member, team: team, user: assignee)
    create(
      :crm_task_type,
      account: account,
      code: 'concurrent-create',
      customer_task_assignee: assignee,
      customer_task_team: team
    )
  end

  def subscribe_to_task_inserts(barrier, attempts)
    subscriber = Class.new do
      def initialize(barrier, attempts)
        @barrier = barrier
        @attempts = attempts
      end

      def start(_name, _id, payload)
        return unless payload[:sql].start_with?('INSERT INTO "crm_tasks"')

        @attempts << Thread.current.object_id
        @barrier.wait
      end

      def finish(*) end
    end.new(barrier, attempts)

    ActiveSupport::Notifications.subscribe('sql.active_record', subscriber)
  end

  def track_default_plan_runs(runs)
    allow(Reminders::DefaultPlanService).to receive(:new).and_wrap_original do |constructor, *args, **kwargs|
      service = constructor.call(*args, **kwargs)
      allow(service).to receive(:perform).and_wrap_original do |perform|
        runs << Thread.current.object_id
        perform.call
      end
      service
    end
  end

  def cleanup_task_side_effects(account)
    return unless account

    task_ids = Crm::Task.where(account_id: account.id).pluck(:id)
    Notification.where(primary_actor_type: 'Crm::Task', primary_actor_id: task_ids).delete_all
    Reminder.where(remindable_type: 'Crm::Task', remindable_id: task_ids).delete_all
    Crm::Event.where(eventable_type: 'Crm::Task', eventable_id: task_ids).delete_all
    Crm::Task.where(id: task_ids).delete_all
  end
end
