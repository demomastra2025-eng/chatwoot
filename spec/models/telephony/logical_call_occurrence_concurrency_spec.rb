require 'rails_helper'
require 'timeout'

# rubocop:disable RSpec/DescribeClass
RSpec.describe 'Telephony logical occurrence concurrency' do
  self.use_transactional_tests = false

  let!(:account) { create(:account, settings: { 'workspace_timezone' => 'UTC' }) }

  after do
    Telephony::LogicalCallOccurrence.transaction do
      account.send(:authorize_participant_lifecycle_fact_teardown)
      Telephony::LogicalCallOccurrence.where(account_id: account.id).delete_all
    end
    Telephony::CallSession.where(account_id: account.id).delete_all
    Account.where(id: account.id).delete_all
  end

  it 'serializes concurrent sibling initiation on the stable logical key' do
    logical_key = 'native-sip:concurrent-logical-call'
    sessions = %w[root sibling].map do |suffix|
      create(
        :telephony_call_session,
        account: account,
        conversation: nil,
        contact: nil,
        inbox: nil,
        number_binding: nil,
        provider: 'sipuni',
        external_call_ref: "sipuni:concurrent-#{suffix}",
        direction: 'inbound',
        started_at: nil,
        from_number: '+15550000000',
        to_number: '+15559999999',
        metadata: { 'metadata' => { 'logical_call_key' => logical_key } }
      )
    end
    started_at = Time.current.change(usec: 0)
    barrier = Concurrent::CyclicBarrier.new(2)

    results = sessions.map do |session|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          barrier.wait
          session.reload.update!(started_at: started_at)
        rescue StandardError => e
          e
        end
      end
    end.map(&:value)

    expect(results).to all(be(true))
    facts = Telephony::LogicalCallOccurrence.where(account_id: account.id)
    expect(facts.where(occurrence_kind: 'attempted').count).to eq(1)
    expect(facts.distinct.count(:logical_call_identity)).to eq(1)
  end

  it 'does not backdate a sibling revision that waited for the account lock' do # rubocop:disable RSpec/ExampleLength
    logical_key = 'native-sip:inverted-revision'
    sessions = %w[first second].map do |suffix|
      create(:telephony_call_session, account: account, conversation: nil, contact: nil, inbox: nil,
                                      number_binding: nil, provider: 'sipuni', external_call_ref: "sipuni:#{suffix}",
                                      direction: 'inbound', started_at: nil, from_number: '+155****0000',
                                      to_number: '+155****9999',
                                      metadata: { 'metadata' => { 'logical_call_key' => logical_key } })
    end
    started_at = 1.minute.ago
    paused = Queue.new
    release = Queue.new
    allow_any_instance_of(Telephony::LogicalCallOccurrenceRecorder).to receive(:with_account_snapshot_lock).and_wrap_original do |original, &block| # rubocop:disable RSpec/AnyInstance
      if Thread.current[:pause_logical_lock]
        paused << true
        release.pop
      end
      original.call(&block)
    end

    first = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Thread.current[:pause_logical_lock] = true
        sessions.first.reload.update!(started_at: started_at, status: 'in_progress',
                                      answered_at: started_at + 5.seconds)
      end
    end
    begin
      Timeout.timeout(30) { paused.pop }
      second = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          sessions.second.reload.update!(started_at: started_at, status: 'in_progress',
                                         answered_at: started_at + 10.seconds)
        end
      end
      expect(Timeout.timeout(30) { second.value }).to be(true)
      original = Telephony::LogicalCallOccurrence.find_by!(occurrence_kind: 'connected', revision: 1)
      cutoff = Time.current.utc.iso8601(6)
      params = { from_local: (started_at - 1.hour).utc.strftime('%Y-%m-%dT%H:%M:%S'),
                 to_local: (started_at + 1.hour).utc.strftime('%Y-%m-%dT%H:%M:%S'),
                 as_of: cutoff, metric: 'connected' }
      report = lambda do
        Telephony::Reports::LogicalCallsQuery.new(account: account,
                                                  occurrences_scope: account.telephony_logical_call_occurrences,
                                                  params: params)
      end
      before = report.call
      before_id = before.drill_down_rows.first.fetch(:occurrence_id)
      before_fingerprint = before.meta.fetch(:query_fingerprint)
    ensure
      release << true
      Timeout.timeout(30) { first.value }
    end

    revised = Telephony::LogicalCallOccurrence.find_by!(occurrence_kind: 'connected', revision: 2)
    after = report.call
    expect(revised.created_at).to be > Time.iso8601(cutoff)
    expect(revised.created_at).to be > original.created_at
    expect(after.drill_down_rows.first.fetch(:occurrence_id)).to eq(before_id)
    expect(after.meta.fetch(:query_fingerprint)).to eq(before_fingerprint)
  end

  it 'waits for an inserted but uncommitted revision before reading a fixed as_of' do # rubocop:disable RSpec/ExampleLength
    started_at = 1.minute.ago
    key = 'native-sip:in-flight-revision'
    first = create(:telephony_call_session, account: account, conversation: nil, contact: nil, inbox: nil,
                                            number_binding: nil, provider: 'sipuni', external_call_ref: 'sipuni:original',
                                            direction: 'inbound', started_at: started_at, status: 'in_progress',
                                            answered_at: started_at + 10.seconds,
                                            from_number: '+155****0000', to_number: '+155****9999',
                                            metadata: { 'metadata' => { 'logical_call_key' => key } })
    sibling = create(:telephony_call_session, account: account, conversation: nil, contact: nil, inbox: nil,
                                              number_binding: nil, provider: 'sipuni', external_call_ref: 'sipuni:earlier-answer',
                                              direction: 'inbound', started_at: nil,
                                              from_number: '+155****0000', to_number: '+155****9999',
                                              metadata: { 'metadata' => { 'logical_call_key' => key } })
    original = Telephony::LogicalCallOccurrence.find_by!(source_id: first.id, occurrence_kind: 'connected')
    inserted = Queue.new
    release = Queue.new
    writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Telephony::CallSession.transaction do
          sibling.reload.update!(started_at: started_at, status: 'in_progress', answered_at: started_at + 5.seconds)
          inserted << true
          release.pop
        end
      end
    end

    begin
      Timeout.timeout(30) { inserted.pop }
      cutoff = Time.current.utc.iso8601(6)
      params = { from_local: (started_at - 1.hour).utc.strftime('%Y-%m-%dT%H:%M:%S'),
                 to_local: (started_at + 1.hour).utc.strftime('%Y-%m-%dT%H:%M:%S'),
                 as_of: cutoff, metric: 'connected' }
      results = Queue.new
      reader = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          query = Telephony::Reports::LogicalCallsQuery.new(
            account: account, occurrences_scope: account.telephony_logical_call_occurrences, params: params
          )
          results << [query.drill_down_rows.first.fetch(:occurrence_id), query.meta.fetch(:query_fingerprint)]
        rescue StandardError => e
          results << e
        end
      end
      expect { Timeout.timeout(0.5) { results.pop } }.to raise_error(Timeout::Error)
    ensure
      release << true
      Timeout.timeout(30) { writer.value }
      Timeout.timeout(30) { reader&.value }
    end

    revised = Telephony::LogicalCallOccurrence.find_by!(occurrence_kind: 'connected', revision: 2)
    expect(revised.supersedes_occurrence_id).to eq(original.id)
    expect(revised.created_at).to be <= Time.iso8601(cutoff)
    expect(results.pop).to eq([revised.id, Telephony::Reports::LogicalCallsQuery.new(
      account: account, occurrences_scope: account.telephony_logical_call_occurrences, params: params
    ).meta.fetch(:query_fingerprint)])
  end
end
# rubocop:enable RSpec/DescribeClass
