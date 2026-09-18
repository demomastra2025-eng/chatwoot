require 'rails_helper'
require 'timeout'

RSpec.describe AccessControl::AccessRoleMutator, '.update' do
  self.use_transactional_tests = false

  around do |example|
    ClimateControl.modify(ACCESS_ROLE_MUTATIONS_ENABLED: 'true') { example.run }
  end

  it 'allows exactly one of two writers with the same lock version' do
    account = create(:account)
    AccessControl::SystemRoleBootstrapper.call(account: account)
    account_user = create(:account_user, account: account, role: :agent)
    AccessControl::ModeTransition.call(account: account, to: :shadow)
    AccessControl::ModeTransition.call(account: account, to: :enforced)
    role = described_class.create(
      account: account,
      attributes: { 'name' => 'Support', 'grants' => [] }
    )
    expected_version = role.lock_version
    ready = Queue.new
    release = Queue.new
    results = Queue.new

    writers = Array.new(2) do |index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          writer_account = Account.find(account.id)
          writer_role = AccessRole.find(role.id)
          ready << true
          release.pop
          described_class.update(
            account: writer_account,
            access_role: writer_role,
            attributes: { 'description' => "Writer #{index}", 'lock_version' => expected_version }
          )
          results << 'updated'
        rescue described_class::Error => e
          results << e.code
        end
      end
    end

    2.times { Timeout.timeout(3) { ready.pop } }
    2.times { release << true }
    writers.each { |writer| Timeout.timeout(5) { writer.join } }

    expect(Array.new(2) { results.pop }).to contain_exactly('updated', 'STALE_ACCESS_ROLE')
    expect(role.reload.description).to match(/Writer [01]/)
  ensure
    2.times { release << true } if defined?(release)
    writers&.each(&:join)
    CustomRole.where(account_id: account&.id).find_each(&:destroy!)
    Account.find_by(id: account&.id)&.destroy!
    User.find_by(id: account_user&.user_id)&.destroy!
  end
end
