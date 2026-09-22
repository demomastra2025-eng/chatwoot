require 'rails_helper'

RSpec.describe AccessControl::LegacyRoleAssigner, :no_transactional_tests do
  self.use_transactional_tests = false

  it 'uses account-first locking so backfill and reactivation both complete' do
    account = create(:account)
    AccessControl::SystemRoleBootstrapper.call(account: account)
    admin = create(:user)
    operator = create(:user)
    create(:account_user, account: account, user: admin, role: :administrator)
    operator_account_user = create(:account_user, account: account, user: operator, role: :agent)
    snapshot = create(
      :account_user_lifecycle_snapshot,
      account: account,
      user: operator,
      role: 'agent',
      access_role: operator_account_user.access_role
    )
    operator_account_user.destroy!
    AccessControl::ModeTransition.call(account: account, to: :shadow)
    service = Captain::Tools::Account::ReactivateUserService.new(create(:captain_assistant, account: account), user: admin)
    backfill_account = Account.find(account.id)
    reactivation_at_create = Queue.new
    backfill_attempting_account_lock = Queue.new
    release_reactivation = Queue.new
    results = Queue.new
    threads = []

    allow(service).to receive(:create_account_user!).and_wrap_original do |original, *args, **kwargs|
      reactivation_at_create << true
      release_reactivation.pop
      original.call(*args, **kwargs)
    end
    allow(backfill_account).to receive(:with_lock).and_wrap_original do |original, *args, **kwargs, &block|
      backfill_attempting_account_lock << true
      original.call(*args, **kwargs, &block)
    end

    threads << run_thread(results, :reactivated) do
      service.send(:reactivate_user, operator.reload, snapshot_id: snapshot.id, role: nil, availability: nil)
    end
    wait_for_signal(reactivation_at_create, results)

    threads << run_thread(results, :backfilled) do
      described_class.call(account: backfill_account, apply: true)
    end

    wait_for_signal(backfill_attempting_account_lock, results)
    expect(threads.last).to be_alive
    release_reactivation << true
    Timeout.timeout(5) { threads.each(&:join) }

    expect(Array.new(2) { results.pop }).to contain_exactly(:reactivated, :backfilled)
    expect(AccountUser.find_by!(account: account, user: operator).access_role_id).to eq(operator_account_user.access_role_id)
    expect(snapshot.reload.reactivated_at).to be_present
  ensure
    release_reactivation << true if defined?(release_reactivation)
    threads&.each { |thread| thread.join(1) }
    account&.destroy!
    User.where(id: [admin&.id, operator&.id]).destroy_all
  end

  def run_thread(results, success)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        yield
        results << success
      rescue StandardError => e
        results << e
      end
    end
  end

  def wait_for_signal(queue, results)
    Timeout.timeout(5) { queue.pop }
  rescue Timeout::Error
    result = results.pop(true)
    raise result if result.is_a?(Exception)

    raise
  rescue ThreadError
    raise Timeout::Error, 'reactivation did not reach AccountUser creation'
  end
end
