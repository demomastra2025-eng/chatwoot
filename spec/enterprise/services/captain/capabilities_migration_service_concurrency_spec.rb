require 'rails_helper'
require 'timeout'

RSpec.describe Captain::CapabilitiesMigrationService do
  self.use_transactional_tests = false

  let(:policy) { 'preserve_ai_expand_mcp_20261102' }

  it 'serializes with the real reactivation User to Account callback without a deadlock', :aggregate_failures do
    account = create(:account)
    actor = create(:super_admin)
    assistant = create(:captain_assistant, :legacy, account: account)
    service = described_class.new(assistant: assistant, actor: actor)
    manifest = Captain::Mcp::ToolCatalog.without_discovery { service.prepare_transition(policy: policy, expected_account_id: account.id) }
    expect(account.account_users.exists?(user: actor)).to be(false)
    results = Queue.new
    user_locked = Queue.new
    release_user = Queue.new
    migration_pid = Queue.new
    reactivator = Captain::Tools::Account::ReactivateUserService.new(assistant, user: actor)
    allow(reactivator).to receive(:create_account_user!).and_wrap_original do |method, *args, **kwargs|
      user_locked << ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()')
      release_user.pop
      method.call(*args, **kwargs)
    end
    reactivation = worker(results, :reactivation) do
      reactivator.send(:reactivate_user, User.find(actor.id), snapshot_id: nil, role: nil, availability: nil)
      :reactivated
    end
    blocker_pid = Timeout.timeout(15) { user_locked.pop }
    migration = worker(results, :migration) do
      migration_pid << ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()')
      Captain::Mcp::ToolCatalog.without_discovery do
        described_class.new(assistant: Captain::Assistant.find(assistant.id), actor: User.find(actor.id))
                       .activate!(expected_digest: manifest[:source_digest], policy: policy, expected_account_id: account.id)
      end
      :migrated
    end
    wait_for_blocking(Timeout.timeout(15) { migration_pid.pop }, blocker_pid)
    release_user << true
    [reactivation, migration].each { |thread| Timeout.timeout(25) { thread.join } }
    expect(2.times.map { results.pop }.to_h).to eq(reactivation: :reactivated, migration: :migrated)
    expect(account.account_users.exists?(user: actor)).to be(true)
    expect(Captain::Capabilities.configured?(assistant.reload.config)).to be(true)
  ensure
    release_user << true if release_user&.empty?
    stop_workers(reactivation, migration)
  end

  it 'rejects authority revoked while activation waits on the actor row, without changing the profile' do
    account = create(:account)
    actor = create(:super_admin)
    assistant = create(:captain_assistant, :legacy, account: account)
    manifest = Captain::Mcp::ToolCatalog.without_discovery do
      described_class.new(assistant: assistant, actor: actor).prepare_transition(policy: policy, expected_account_id: account.id)
    end
    original = assistant.reload.attributes.deep_dup
    ready = Queue.new
    release = Queue.new
    migration_pid = Queue.new
    results = Queue.new
    revocation = worker(results, :revocation) do
      User.find(actor.id).with_lock do
        ready << ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()')
        release.pop
        User.where(id: actor.id).update_all(type: 'User') # rubocop:disable Rails/SkipsModelValidations
      end
      :revoked
    end
    blocker_pid = Timeout.timeout(15) { ready.pop }
    migration = worker(results, :migration) do
      migration_pid << ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()')
      Captain::Mcp::ToolCatalog.without_discovery do
        described_class.new(assistant: Captain::Assistant.find(assistant.id), actor: actor)
                       .activate!(expected_digest: manifest[:source_digest], policy: policy, expected_account_id: account.id)
      end
    rescue Captain::AssistantConfigContract::Violation => e
      e.code
    end
    wait_for_blocking(Timeout.timeout(15) { migration_pid.pop }, blocker_pid)
    release << true
    [revocation, migration].each { |thread| Timeout.timeout(25) { thread.join } }
    expect(2.times.map { results.pop }.to_h).to eq(revocation: :revoked, migration: 'platform_managed_capabilities')
    expect(assistant.reload.attributes).to eq(original)
  ensure
    release << true if release&.empty?
    stop_workers(revocation, migration)
  end

  def worker(results, name)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { results << [name, yield] }
    rescue StandardError => e
      results << [name, e.class.name]
    end
  end

  def wait_for_blocking(waiter, blocker)
    Timeout.timeout(15) do
      loop do
        sql = ActiveRecord::Base.sanitize_sql_array(['SELECT ? = ANY(pg_blocking_pids(?))', blocker, waiter])
        break if ActiveRecord::Base.connection.select_value(sql)

        Thread.pass
      end
    end
  end

  def stop_workers(*threads)
    threads.compact.each do |thread|
      thread.join(10)
      next unless thread.alive?

      thread.kill
      thread.join(5)
    end
  end
end
