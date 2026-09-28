require 'rails_helper'
require 'timeout'

RSpec.describe Captain::CustomerToolExecutionScope do
  self.use_transactional_tests = false

  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:other_contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let(:state) do
    { account_id: account.id, assistant_id: assistant.id,
      conversation: { id: conversation.id }, contact: { id: contact.id } }
  end

  def wait_for_block!(blocked_pid, blocker_pid)
    Timeout.timeout(15) do
      loop do
        blockers = ActiveRecord::Base.connection.select_value("SELECT pg_blocking_pids(#{blocked_pid})")
        break if blockers.include?(blocker_pid.to_s)

        sleep 0.01
      end
    end
  end

  # Real PostgreSQL barriers require two connections and deliberately verbose coordination.
  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
  def race_tool_with_rebind(tool, arguments, thread: nil)
    state
    other_contact
    held = Queue.new
    release = Queue.new
    rebinder_started = Queue.new
    allow(Captain::ToolExecutionAuditService).to receive(:record)
    allow(tool).to receive(:ensure_tool_execution_allowed!).and_wrap_original do |method|
      method.call
      held << ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()').to_i
      release.pop
    end
    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        context = Captain::Runtime::ToolContext.new(
          run_context: Captain::Runtime::RunContext.new({ state: state })
        )
        tool.execute(context, **arguments)
      end
    rescue StandardError => e
      e
    end
    locked_pid = Timeout.timeout(15) { held.pop }
    rebinder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        rebinder_started << ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()').to_i
        Conversation.transaction do
          # rubocop:disable Rails/SkipsModelValidations -- model the production merge's bulk FK rebind
          Conversation.where(id: conversation.id).update_all(contact_id: other_contact.id)
          CommunicationThread.where(id: thread.id).update_all(contact_id: other_contact.id) if thread
          # rubocop:enable Rails/SkipsModelValidations
        end
      end
    rescue StandardError => e
      e
    end
    wait_for_block!(Timeout.timeout(15) { rebinder_started.pop }, locked_pid)
    release << true
    result = Timeout.timeout(20) { worker.value }
    rebound = Timeout.timeout(20) { rebinder.value }
    raise result if result.is_a?(StandardError)
    raise rebound if rebound.is_a?(StandardError)

    expect(conversation.reload.contact_id).to eq(other_contact.id)
    result
  ensure
    release&.push(true)
    [worker, rebinder].compact.each { |running| Timeout.timeout(15) { running.value } if running.alive? }
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

  it 'commits an update to the original Contact before a competing rebind can commit' do
    result = race_tool_with_rebind(Captain::Tools::UpdateContactTool.new(assistant), { name: 'Before rebind' })

    expect(JSON.parse(result).dig('contact', 'id')).to eq(contact.id)
    expect(contact.reload.name).to eq('Before rebind')
    expect(other_contact.reload.name).not_to eq('Before rebind')
  end

  it 'denies a stale update when a merge-style rebind holds the Contact identity lock first' do
    state
    other_contact
    held = Queue.new
    release = Queue.new
    tool_started = Queue.new
    allow(Captain::ToolExecutionAuditService).to receive(:record)
    merger = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Contact.transaction do
          Contacts::PhoneIdentityLock.acquire!(account_id: account.id)
          Contact.where(id: contact.id).lock.first
          Conversation.where(id: conversation.id).update_all(contact_id: other_contact.id) # rubocop:disable Rails/SkipsModelValidations -- simulate bulk merge
          held << ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()').to_i
          release.pop
        end
      end
    rescue StandardError => e
      e
    end
    merger_pid = Timeout.timeout(15) { held.pop }
    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        tool_started << ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()').to_i
        context = Captain::Runtime::ToolContext.new(run_context: Captain::Runtime::RunContext.new({ state: state }))
        Captain::Tools::UpdateContactTool.new(assistant).execute(context, name: 'Stale update')
      end
    rescue StandardError => e
      e
    end
    wait_for_block!(Timeout.timeout(15) { tool_started.pop }, merger_pid)
    release << true
    expect(Timeout.timeout(20) { worker.value }).to be_a(Captain::CustomerToolExecutionScope::Denied)
    raise merger.value if merger.value.is_a?(StandardError)

    expect(conversation.reload.contact_id).to eq(other_contact.id)
    expect(contact.reload.name).not_to eq('Stale update')
    expect(other_contact.reload.name).not_to eq('Stale update')
  ensure
    release&.push(true)
    [worker, merger].compact.each { |running| Timeout.timeout(15) { running.value } if running.alive? }
  end

  it 'denies a backdated cross-channel incoming committed after tool precheck on another PostgreSQL connection' do
    conversation.update!(status: :pending)
    create(:captain_inbox, captain_assistant: assistant, inbox: conversation.inbox)
    trigger = create(:message, account: account, conversation: conversation,
                               inbox: conversation.inbox, message_type: :incoming)
    state[:captain_response_fence] = {
      control_generation: conversation.current_captain_control_generation,
      last_message_id: trigger.id
    }
    other_inbox = create(:inbox, account: account)
    sibling = create(:conversation, account: account, inbox: other_inbox, contact: contact)
    tool = Captain::Tools::UpdateContactTool.new(assistant)
    reached_precheck = Queue.new
    release_tool = Queue.new
    allow(Captain::ToolExecutionAuditService).to receive(:record)
    allow(tool).to receive(:ensure_captain_control_current!).and_wrap_original do |method, *args|
      method.call(*args)
      reached_precheck << ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()').to_i
      release_tool.pop
    end
    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        context = Captain::Runtime::ToolContext.new(run_context: Captain::Runtime::RunContext.new({ state: state }))
        tool.execute(context, name: 'Stale backdated update')
      end
    rescue StandardError => e
      e
    end
    worker_pid = Timeout.timeout(15) { reached_precheck.pop }
    expect(worker_pid).not_to eq(ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()').to_i)
    newer = create(:message, account: account, inbox: other_inbox, conversation: sibling,
                             message_type: :incoming, created_at: trigger.created_at - 1.minute)
    expect(newer.id).to be > trigger.id
    release_tool << true

    expect(Timeout.timeout(20) { worker.value }).to be_a(Captain::Conversation::ControlGenerationStaleError)
    expect(contact.reload.name).not_to eq('Stale backdated update')
  ensure
    release_tool&.push(true)
    Timeout.timeout(20) { worker.value } if worker&.alive?
  end

  it 'keeps customer task mutation on the original Contact/thread until it commits' do
    account.enable_features!('crm_tasks')
    thread = create(:communication_thread, account: account, contact: contact)
    create(:communication_thread_conversation, communication_thread: thread, conversation: conversation, primary: true)
    task = create(:crm_task, account: account, originating_conversation: conversation,
                             customer_visible: true, customer_title: 'Before task')
    result = race_tool_with_rebind(
      Captain::Tools::CustomerTasksTool.new(assistant),
      { action: 'update', task_id: task.id, title: 'Safe task', idempotency_key: 'race-customer-task' },
      thread: thread
    )

    expect(JSON.parse(result)).to include('action' => 'updated')
    expect(task.reload.customer_title).to eq('Safe task')
  ensure
    if task
      Notification.where(primary_actor: task).delete_all
      Reminder.where(remindable: task).delete_all
      Crm::Event.where(eventable: task).delete_all
      task.delete
    end
    CommunicationThreadConversation.where(communication_thread_id: thread.id).delete_all if thread
    thread&.delete
  end

  # The real two-connection INSERT interleaving and side-effect checks need a verbose example.
  # rubocop:disable RSpec/ExampleLength
  it 'replays a customer create after an external task writer wins the PostgreSQL unique index', :aggregate_failures do
    account.enable_features!('crm_tasks')
    thread = create(:communication_thread, account: account, contact: contact)
    create(:communication_thread_conversation, communication_thread: thread, conversation: conversation, primary: true)
    sibling = create(:conversation, account: account, contact: contact)
    create(:communication_thread_conversation, communication_thread: thread, conversation: sibling)
    Crm::Bootstrap::AccountService.new(account: account).perform
    assignee = create(:user)
    create(:account_user, account: account, user: assignee)
    team = create(:team, account: account)
    create(:team_member, team: team, user: assignee)
    task_type = create(
      :crm_task_type, account: account, code: 'pg-race',
                      customer_task_assignee: assignee, customer_task_team: team
    )
    key = 'customer-task-cross-writer-pg-unique'
    insert_started = Queue.new
    release_insert = Queue.new
    sql_inserts = Queue.new
    failed_inserts = Queue.new
    default_plan_runs = Queue.new
    subscriber = subscribe_to_customer_insert(insert_started, release_insert, sql_inserts, failed_inserts)
    allow(Reminders::DefaultPlanService).to receive(:new).and_wrap_original do |constructor, *args, **kwargs|
      service = constructor.call(*args, **kwargs)
      allow(service).to receive(:perform).and_wrap_original do |perform|
        default_plan_runs << true
        perform.call
      end
      service
    end
    allow(Captain::ToolExecutionAuditService).to receive(:record)
    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        Thread.current[:customer_scope_insert] = true
        pid = connection.select_value('SELECT pg_backend_pid()').to_i
        context = Captain::Runtime::ToolContext.new(run_context: Captain::Runtime::RunContext.new({ state: state }))
        result = Captain::Tools::CustomerTasksTool.new(assistant).execute(
          context, action: 'create', title: 'Attempted create', task_type: task_type.code, idempotency_key: key
        )
        [pid, JSON.parse(result), connection.open_transactions]
      end
    rescue StandardError => e
      e
    end
    Timeout.timeout(20) { insert_started.pop }
    writer_pid = ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()').to_i
    original = Timeout.timeout(20) do
      Crm::Tasks::UpsertService.new(
        account: account, actor: nil,
        params: {
          title: 'External original', customer_visible: true, customer_title: 'External original',
          context_kind: 'personal', task_type_id: task_type.id, assignee_id: assignee.id,
          team_id: team.id, originating_conversation_id: sibling.id, idempotency_key: key
        }
      ).perform
    end
    release_insert << true
    replay = Timeout.timeout(20) { worker.value }
    raise replay if replay.is_a?(StandardError)

    expect(replay.first).not_to eq(writer_pid)
    expect(replay.last).to eq(0)
    expect(replay.second['action']).to eq('created')
    expect(replay.second.dig('task', 'id')).to eq(original.id)
    expect(replay.second.dig('task', 'title')).to eq('External original')
    expect(sql_inserts.size).to eq(2)
    expect(failed_inserts.size).to eq(1)
    expect(failed_inserts.pop(true)).to eq('ActiveRecord::RecordNotUnique')
    expect(failed_inserts).to be_empty
    expect(account.crm_tasks.where(idempotency_key: key).count).to eq(1)
    expect(original.events.where(event_type: 'task_created', command_key: key).count).to eq(1)
    expect(Notification.where(primary_actor: original, notification_type: 'task_assignment').count).to eq(1)
    expect(default_plan_runs.size).to eq(1)
    # A failed savepoint must not leave the outer account/Contact lock or transaction alive.
    expect(ActiveRecord::Base.connection.select_value("SELECT pg_try_advisory_xact_lock(#{phone_lock_id(account.id)})")).to be(true)
  ensure
    release_insert&.push(true)
    Timeout.timeout(20) { worker.value } if worker&.alive?
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    if account&.persisted?
      task_ids = Crm::Task.where(account_id: account.id).pluck(:id)
      Notification.where(primary_actor_type: 'Crm::Task', primary_actor_id: task_ids).delete_all
      Reminder.where(remindable_type: 'Crm::Task', remindable_id: task_ids).delete_all
      Crm::Event.where(eventable_type: 'Crm::Task', eventable_id: task_ids).delete_all
      Crm::Task.where(id: task_ids).delete_all
      CommunicationThreadConversation.where(communication_thread_id: thread.id).delete_all if thread
      thread&.delete
    end
  end
  # rubocop:enable RSpec/ExampleLength

  def subscribe_to_customer_insert(started, release, attempts, failures)
    listener = Struct.new(:started, :release, :attempts, :failures) do
      def start(_name, _id, payload)
        return unless payload[:sql].start_with?('INSERT INTO "crm_tasks"')

        attempts << Thread.current.object_id
        return unless Thread.current[:customer_scope_insert]

        started << true
        Timeout.timeout(20) { release.pop }
      end

      def finish(_name, _id, payload)
        return unless Thread.current[:customer_scope_insert] && payload[:sql].start_with?('INSERT INTO "crm_tasks"')

        failures << payload[:exception].first if payload[:exception]
      end
    end.new(started, release, attempts, failures)
    ActiveSupport::Notifications.subscribe('sql.active_record', listener)
  end

  def phone_lock_id(account_id)
    Digest::SHA256.digest("#{Contacts::PhoneIdentityLock::PREFIX}:#{account_id}").unpack1('q>')
  end
end
