require 'rails_helper'
require 'timeout'

RSpec.describe AccessControl::ModeTransition, '.call' do
  self.use_transactional_tests = false

  it 'serializes enforcement with a concurrent legacy-identity writer' do
    account = create(:account)
    roles = AccessControl::SystemRoleBootstrapper.call(account: account).roles_by_key
    account_user = create(:account_user, account: account, role: :agent)
    described_class.call(account: account, to: :shadow)
    readiness = AccessControl::EnforcementReadiness.call(account: account)
    transition_locked = Queue.new
    release_transition = Queue.new
    writer_started = Queue.new
    writer_finished = Queue.new

    allow(AccessControl::EnforcementReadiness).to receive(:call) do
      transition_locked << true
      release_transition.pop
      readiness
    end

    transition = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        described_class.call(account: Account.find(account.id), to: :enforced)
      end
    end
    transition_locked.pop

    writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        writer_started << true
        AccountUser.find(account_user.id).update!(role: :administrator)
        writer_finished << true
      end
    end
    writer_started.pop

    expect { Timeout.timeout(0.2) { writer_finished.pop } }.to raise_error(Timeout::Error)
    release_transition << true
    expect(Timeout.timeout(3) { writer_finished.pop }).to be(true)
    transition.value
    writer.value

    expect(account.reload).to be_access_control_mode_enforced
    expect(account_user.reload).to be_administrator
    expect(account_user.access_role).to eq(roles.fetch('administrator'))
  ensure
    release_transition << true if defined?(release_transition)
    transition&.join
    writer&.join
    Account.find_by(id: account&.id)&.destroy!
    User.find_by(id: account_user&.user_id)&.destroy!
  end

  it 'rejects a concurrent lifecycle snapshot mismatch after enforcement wins the account lock' do
    account = create(:account)
    roles = AccessControl::SystemRoleBootstrapper.call(account: account).roles_by_key
    snapshot = create(
      :account_user_lifecycle_snapshot,
      account: account,
      role: 'agent',
      access_role: roles.fetch('employee')
    )
    described_class.call(account: account, to: :shadow)
    readiness = AccessControl::EnforcementReadiness.call(account: account)
    transition_locked = Queue.new
    release_transition = Queue.new
    writer_started = Queue.new
    writer_result = Queue.new

    allow(AccessControl::EnforcementReadiness).to receive(:call) do
      transition_locked << true
      release_transition.pop
      readiness
    end

    transition = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        described_class.call(account: Account.find(account.id), to: :enforced)
      end
    end
    transition_locked.pop

    writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        writer_started << true
        AccountUserLifecycleSnapshot.find(snapshot.id).update!(role: 'administrator')
        writer_result << 'updated'
      rescue StandardError => e
        writer_result << e.class.name
      end
    end
    writer_started.pop

    expect { Timeout.timeout(0.2) { writer_result.pop } }.to raise_error(Timeout::Error)
    release_transition << true
    expect(Timeout.timeout(3) { writer_result.pop }).to eq('ActiveRecord::RecordInvalid')
    transition.value
    writer.value

    expect(account.reload).to be_access_control_mode_enforced
    expect(snapshot.reload).to have_attributes(role: 'agent', access_role_id: roles.fetch('employee').id)
  ensure
    release_transition << true if defined?(release_transition)
    transition&.join
    writer&.join
    Account.find_by(id: account&.id)&.destroy!
    User.find_by(id: snapshot&.user_id)&.destroy!
  end
end
