require 'rails_helper'
require 'timeout'

RSpec.describe Captain::Tools::ProviderBookingHandoffService do
  self.use_transactional_tests = false

  # Rows committed here are not rolled back, and Account#destroy! leaves conversations, inboxes and
  # contacts to destroy_async jobs that never run in specs. Clear them so later specs start clean.
  after do
    connection = ActiveRecord::Base.connection
    connection.truncate_tables(*(connection.tables - %w[schema_migrations ar_internal_metadata]))
  end

  def run_retry(conversation:, assistant:, fence:, results:, backend_pids:)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        backend_pids << connection.select_value('SELECT pg_backend_pid()')
        record = Conversation.find(conversation.id)
        results << described_class.new(assistant: assistant, conversation: record, fence: fence).perform
      end
    rescue StandardError => e
      results << e
    end
  end

  def instrument_note_path(entered_handoff:, inside_first_note:, release_first_note:)
    mutex = Mutex.new
    paused = false
    # Both DB connections must overlap inside the note path; the second waits on the row lock.
    # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(described_class).to receive(:handoff!).and_wrap_original do |original|
      entered_handoff << true
      original.call
    end
    allow_any_instance_of(described_class).to receive(:create_staff_note!).and_wrap_original do |original|
      first = mutex.synchronize do
        next false if paused

        paused = true
      end
      if first
        inside_first_note << true
        release_first_note.pop
      end
      original.call
    end
    # rubocop:enable RSpec/AnyInstance
  end

  it 'writes one note for overlapping no-command retries after a human takeover' do
    account = create(:account, locale: 'ru')
    assistant = create(:captain_assistant, account: account, usage_mode: 'external_agent')
    conversation = create(:conversation, account: account, status: :pending)
    create(:captain_inbox, inbox: conversation.inbox, captain_assistant: assistant)
    incoming = create(:message, conversation: conversation, message_type: :incoming)
    fence = {
      control_generation: conversation.current_captain_control_generation,
      status_transition_id: conversation.status_transitions.maximum(:id).to_i,
      last_message_id: incoming.id
    }
    conversation.update!(status: :open)

    inside_first_note = Queue.new
    release_first_note = Queue.new
    entered_handoff = Queue.new
    results = Queue.new
    backend_pids = Queue.new
    instrument_note_path(entered_handoff: entered_handoff, inside_first_note: inside_first_note, release_first_note: release_first_note)

    first = run_retry(conversation: conversation, assistant: assistant, fence: fence, results: results, backend_pids: backend_pids)
    Timeout.timeout(10) do
      entered_handoff.pop
      inside_first_note.pop
    end
    second = run_retry(conversation: conversation, assistant: assistant, fence: fence, results: results, backend_pids: backend_pids)
    Timeout.timeout(10) { entered_handoff.pop }
    first_pid, second_pid = Timeout.timeout(10) { [backend_pids.pop, backend_pids.pop] }
    expect(second_pid).not_to eq(first_pid)
    Timeout.timeout(10) do
      loop do
        sql = ActiveRecord::Base.sanitize_sql_array(['SELECT wait_event_type FROM pg_stat_activity WHERE pid = ?', second_pid])
        break if ActiveRecord::Base.connection.select_value(sql) == 'Lock'

        sleep 0.01
      end
    end
    release_first_note << true
    [first, second].each { |worker| Timeout.timeout(10) { worker.join } }

    expect([results.pop, results.pop]).to eq(%i[stale stale])
    expect(conversation.reload.status).to eq('open')
    expect(conversation.messages.outgoing.where(private: true).count).to eq(1)
    expect(conversation.messages.outgoing.where(private: false)).to be_empty
  ensure
    release_first_note << true if defined?(release_first_note) && release_first_note.empty?
    first&.join(10)
    second&.join(10)
    account&.destroy!
  end
end
