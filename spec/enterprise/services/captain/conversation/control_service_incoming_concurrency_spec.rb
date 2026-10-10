require 'rails_helper'
require 'timeout'

RSpec.describe Captain::Conversation::ControlService do
  self.use_transactional_tests = false

  after { CommittedRowsCleanup.truncate! }

  it 'rejects an incoming-request fence after a competing connection commits while handoff waits on its row lock' do
    records = create_incoming_race_records
    conversation = records.fetch(:conversation)
    original = records.fetch(:incoming)
    generation = conversation.current_captain_control_generation
    status_epoch = conversation.status_transitions.maximum(:id).to_i
    incoming_ready = Queue.new
    release_incoming = Queue.new
    incoming_results = Queue.new
    handoff_results = Queue.new
    callbacks = Queue.new
    handoff_pids = Queue.new

    incoming_worker = hold_incoming_transaction(records, incoming_ready, release_incoming, incoming_results)
    incoming_pid, new_message_id = Timeout.timeout(10) { incoming_ready.pop }
    expect(new_message_id).to be > original.id
    # The other connection has inserted the row, but it is not yet committed.
    expect(conversation.messages.incoming.pluck(:id)).to eq([original.id])

    fence = {
      control_generation: generation, status_transition_id: status_epoch,
      last_message_id: original.id, require_current_incoming: true
    }
    handoff_worker = run_incoming_handoff(records, fence, handoff_pids, handoff_results, callbacks)
    handoff_pid = Timeout.timeout(10) { handoff_pids.pop }
    expect(handoff_pid).not_to eq(incoming_pid)
    wait_for_row_lock(handoff_pid, incoming_pid)

    release_incoming << true
    [incoming_worker, handoff_worker].each { |worker| Timeout.timeout(10) { worker.join } }

    expect(incoming_results.pop).to eq(new_message_id)
    expect(handoff_results.pop).to eq(:stale)
    expect(callbacks).to be_empty
    expect(conversation.reload).to be_pending
    expect(conversation.current_captain_control_generation).to eq(generation)
    expect(records.fetch(:thread).reload.captain_handoff_applied_at).to be_nil
    expect(conversation.status_transitions.maximum(:id).to_i).to eq(status_epoch)
    expect(conversation.messages.outgoing).to be_empty
    expect(conversation.messages.incoming.reorder(created_at: :desc, id: :desc).pick(:id)).to eq(new_message_id)
  ensure
    release_incoming << true if release_incoming&.empty?
    [incoming_worker, handoff_worker].compact.each do |worker|
      worker.join(10)
      next unless worker.alive?

      worker.kill
      worker.join(5)
    end
  end

  def create_incoming_race_records
    account = create(:account)
    conversation = create(:conversation, account: account, status: :pending)
    assistant = create(:captain_assistant, account: account, usage_mode: 'external_agent')
    create(:captain_inbox, inbox: conversation.inbox, captain_assistant: assistant)
    thread = create(:communication_thread, account: account, contact: conversation.contact)
    create(:communication_thread_conversation, communication_thread: thread, conversation: conversation)
    conversation.association(:communication_thread_conversation).reset
    conversation.association(:communication_thread).reset
    incoming = create(:message, conversation: conversation, message_type: :incoming, skip_runtime_events: true)

    { conversation: conversation, assistant: assistant, thread: thread, incoming: incoming }
  end

  def hold_incoming_transaction(records, ready, release, results)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        pid = connection.select_value('SELECT pg_backend_pid()')
        message = nil
        locked = Conversation.find(records.fetch(:conversation).id)
        locked.with_lock do
          # Equal timestamps also exercise the id tie-breaker used by incoming fences.
          message = create(
            :message, conversation: locked, message_type: :incoming,
            created_at: records.fetch(:incoming).created_at, skip_runtime_events: true
          )
          ready << [pid, message.id]
          release.pop
        end
        results << message.id
      end
    rescue StandardError => e
      results << e
    end
  end

  def run_incoming_handoff(records, fence, pids, results, callbacks)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        pids << connection.select_value('SELECT pg_backend_pid()')
        conversation = Conversation.find(records.fetch(:conversation).id)
        result = conversation.bot_handoff!(fence: fence) do
          callbacks << true
          create(
            :message, conversation: conversation, message_type: :outgoing,
            sender: records.fetch(:assistant), content: 'Stale slot-conflict notice', skip_runtime_events: true
          )
        end
        results << result
      end
    rescue StandardError => e
      results << e
    end
  end

  def wait_for_row_lock(pid, blocker_pid)
    Timeout.timeout(10) do
      loop do
        sql = ActiveRecord::Base.sanitize_sql_array(['SELECT ? = ANY(pg_blocking_pids(?))', blocker_pid, pid])
        break if ActiveRecord::Base.connection.select_value(sql)

        sleep 0.01
      end
    end
  end
end
