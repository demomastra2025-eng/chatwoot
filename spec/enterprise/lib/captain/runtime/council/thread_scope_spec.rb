require 'rails_helper'

RSpec.describe Captain::Runtime::Council::ThreadScope do
  let(:account) { create(:account) }
  let(:policy) { { 'token' => 'synthetic-playground-token' } }

  around do |example|
    previous_locale = I18n.locale
    previous_zone = Time.zone
    example.run
  ensure
    I18n.locale = previous_locale
    Time.zone = previous_zone
    Current.reset
  end

  def capture_in(context = {})
    Current.account = account
    Current.request_id = 'request-1'
    Current.suppress_runtime_events = true
    Current.playground_run_policy = policy
    I18n.locale = :kk
    Time.zone = 'Asia/Almaty'
    Llm::EventBus.with_context(context) { described_class.capture }
  end

  def on_a_thread(scope, executed_by: nil, &)
    Thread.new do
      Thread.current.report_on_exception = false
      scope.run(executed_by: executed_by, &)
    end.value
  end

  it 'gives a new thread the attributes of Current, the locale, the time zone and the event-bus context of the calling thread' do
    scope = capture_in('request_id' => 'bus-request', 'conversation_id' => 42)
    actor = Object.new

    seen = on_a_thread(scope, executed_by: actor) do
      { account: Current.account, request_id: Current.request_id, suppress: Current.suppress_runtime_events,
        policy: Current.playground_run_policy, executed_by: Current.executed_by, locale: I18n.locale,
        zone: Time.zone.name, bus_request: Llm::EventBus.request_id }
    end

    expect(seen).to eq(account: account, request_id: 'request-1', suppress: true, policy: policy, executed_by: actor, locale: :kk,
                       zone: 'Asia/Almaty', bus_request: 'bus-request')
  end

  it 'blocks external delivery on the thread when the calling thread runs under a Playground policy' do
    scope = capture_in

    blocked = on_a_thread(scope) do
      Outbound::PlaygroundDeliveryPolicy.ensure!(conversation: nil)
      false
    rescue Outbound::PlaygroundDeliveryPolicy::Blocked
      true
    end

    expect(blocked).to be(true)
  end

  it 'copies the policy: the thread cannot change the one of the calling thread' do
    scope = capture_in

    on_a_thread(scope) { Current.playground_run_policy['token'] = 'changed' }

    expect(Current.playground_run_policy['token']).to eq('synthetic-playground-token')
  end

  it 'reads fresh data on the thread: the query cache is off' do
    scope = capture_in

    expect(on_a_thread(scope) { ActiveRecord::Base.connection.query_cache_enabled }).to be(false)
  end

  it 'resets Current when the block ends and lets the calling thread keep its own' do
    scope = capture_in

    after = on_a_thread(scope) do
      Current.account = nil
      :done
    end

    expect(after).to eq(:done)
    expect(Current.account).to eq(account)
    expect(Current.playground_run_policy).to eq(policy)
  end

  it 'runs inside the executor, which gives the connection of the thread back to the pool' do
    scope = capture_in
    allow(Rails.application.executor).to receive(:wrap).and_call_original

    on_a_thread(scope) { ActiveRecord::Base.connection.select_value('SELECT 1') }

    expect(Rails.application.executor).to have_received(:wrap)
  end

  describe 'connection lease cleanup' do
    self.use_transactional_tests = false

    it 'releases an idle lease on a worker before model latency, while retaining a real open transaction' do
      scope = capture_in

      seen = on_a_thread(scope) do
        ActiveRecord::Base.connection.select_value('SELECT 1')
        described_class.release_idle_connections!
        idle = ActiveRecord::Base.connection_pool.active_connection?.present?
        transaction = ActiveRecord::Base.transaction do
          described_class.release_idle_connections!
          described_class.transaction_open?
        end
        [idle, transaction]
      end

      expect(seen).to eq([false, true])
    end
  end

  it 'gives sibling workers independent policy and privacy maps while retaining the run scopes' do
    privacy = { account_id: account.id, scope_id: 'synthetic-council', memory: {}, whitelist: {}, seeded_names: [], seeded_phones: [] }
    scope = Llm::PiiSessionPseudonymizer.adopt_scope(privacy) do
      Llm::IinTokenVault.with_scope(account_id: account.id, scope_id: 'synthetic-council') { capture_in }
    end
    ready = Queue.new
    release = Queue.new
    workers = %w[first second].map do |id|
      Thread.new do
        scope.run do
          Current.playground_run_policy['worker'] = id
          Llm::PiiSessionPseudonymizer.current_scope[:memory]['worker'] = id
          ready << true
          release.pop
          [Current.playground_run_policy['worker'], Llm::PiiSessionPseudonymizer.current_scope[:memory]['worker'],
           Llm::IinTokenVault.current_scope[:scope_id]]
        end
      end
    end
    2.times { Timeout.timeout(5) { ready.pop } }
    2.times { release << true }

    expect(workers.map(&:value)).to eq([%w[first first synthetic-council], %w[second second synthetic-council]])
    expect(Current.playground_run_policy).to eq('token' => 'synthetic-playground-token')
    expect(privacy[:memory]).to eq({})
  ensure
    2.times { release << true } if release
    workers&.each { |worker| worker.join(5) }
  end
end
