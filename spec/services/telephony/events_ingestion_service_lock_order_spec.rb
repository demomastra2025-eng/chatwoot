require 'rails_helper'
require 'timeout'

# The caller's intake lock goes before the call session row, everywhere. A late
# terminal event used to take the session row first (reconcile of a stale
# terminal voice message) and then wait for the intake lock, while any other
# event of the same session held the intake lock and waited for the row: a real
# PostgreSQL deadlock, healed only by the retry after a second.
RSpec.describe Telephony::EventsIngestionService, 'lock order' do
  # Two real connections; the rows are committed and cleared afterwards.
  self.use_transactional_tests = false

  after { CommittedRowsCleanup.truncate! }

  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:call_ref) { "beeline:janus:lockorder-#{SecureRandom.hex(4)}:call-id@sbc.example.test" }
  let!(:call_session) do
    create(
      :telephony_call_session,
      account: account, conversation: conversation, contact: conversation.contact, inbox: inbox,
      provider: 'beeline', direction: 'inbound', status: 'no_answer', external_call_ref: call_ref,
      from_number: '+70000000777', to_number: '+70000000099', ended_at: 1.minute.ago, ended_by: 'system',
      end_reason: 'caller_hangup', metadata: { 'metadata' => { 'route_action' => 'operator' } }
    )
  end

  def event_payload(key, event, status)
    { event_key: key, account_id: account.id, call_ref: call_ref, provider: 'beeline', event: event, event_type: event,
      status: status, direction: 'inbound' }
  end

  def pg_deadlocks
    ActiveRecord::Base.connection.select_value('SELECT deadlocks FROM pg_stat_database WHERE datname = current_database()').to_i
  end

  def run_event(name, payload, results)
    Thread.new do
      Thread.current[:lock_order_name] = name
      ActiveRecord::Base.connection_pool.with_connection do
        described_class.new(payload: payload).perform
        results[name] = :ok
      rescue StandardError => e
        results[name] = "#{e.class}: #{e.message.lines.first&.strip}"
      end
    end
  end

  it 'lets a late terminal event and another event of the same session take turns without a deadlock' do
    t1_in_voice_lock = Queue.new
    reached_stale_terminal_path = false

    # The late terminal event stops where it is about to take the voice group
    # lock (inside the stale terminal reconcile) until the other event had the
    # time to take the intake lock - when it can.
    allow_any_instance_of(described_class).to receive(:with_native_sip_voice_group_lock).and_wrap_original do |original, *args, &block|
      if Thread.current[:lock_order_name] == :late_terminal
        reached_stale_terminal_path = true
        t1_in_voice_lock << true
        sleep 2
      end
      original.call(*args, &block)
    end

    before_count = pg_deadlocks
    results = {}
    late_terminal = run_event(:late_terminal, event_payload("evt-late-#{SecureRandom.hex(3)}", 'operator_no_answer', 'no_answer'), results)
    Timeout.timeout(15) { t1_in_voice_lock.pop }
    other = run_event(:other, event_payload("evt-other-#{SecureRandom.hex(3)}", 'ringing', 'ringing'), results)
    [late_terminal, other].each { |thread| Timeout.timeout(60) { thread.join } }
    # The deadlock counter of PostgreSQL is reported with a small delay.
    sleep 1.5

    expect(reached_stale_terminal_path).to be(true), 'the stale terminal path was not reached: the scenario is invalid'
    expect(results).to eq(late_terminal: :ok, other: :ok)
    expect(pg_deadlocks - before_count).to eq(0)
    expect(account.telephony_events.pluck(:status)).to all(eq('processed'))
  end
end
