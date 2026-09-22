require 'rails_helper'

# rubocop:disable RSpec/DescribeClass
RSpec.describe 'Telephony logical occurrence concurrency' do
  self.use_transactional_tests = false

  let!(:account) { create(:account) }

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
end
# rubocop:enable RSpec/DescribeClass
