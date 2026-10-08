require 'rails_helper'
require 'timeout'

RSpec.describe 'Default inbox membership concurrency', type: :model do
  self.use_transactional_tests = false

  it 'joins an employee and inbox created concurrently without deadlocking or duplicating membership' do
    account = create(:account)
    user = create(:user)
    entered = Queue.new
    release = Queue.new
    errors = Queue.new

    # Both transactions have inserted their account reference before either takes
    # the defaults lock. FOR UPDATE would deadlock on their foreign-key locks.
    allow_any_instance_of(Account).to receive(:with_lock).and_wrap_original do |with_lock, *args, &block|
      entered << true
      release.pop
      with_lock.call(*args, &block)
    end

    inbox_worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        create(:inbox, account: Account.find(account.id))
      end
    rescue StandardError => e
      errors << e
    end
    member_worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        create(:account_user, account: Account.find(account.id), user: User.find(user.id))
      end
    rescue StandardError => e
      errors << e
    end

    Timeout.timeout(5) { 2.times { entered.pop } }
    2.times { release << true }
    Timeout.timeout(10) { [inbox_worker, member_worker].each(&:join) }

    expect(errors.size).to eq(0)
    inbox = account.inboxes.sole
    expect(inbox.members.ids).to eq([user.id])
    expect(inbox.inbox_members.where(user: user).count).to eq(1)
    expect(account.account_users.where(user: user).count).to eq(1)
  ensure
    2.times { release << true } if release
    [inbox_worker, member_worker].compact.each do |worker|
      worker.join(2)
      worker.kill if worker.alive?
    end
    cleanup_membership_records(account, user) if account
  end

  def cleanup_membership_records(account, user)
    # This non-transactional example removes only its own fixture graph.
    inbox_ids = Inbox.where(account_id: account.id).select(:id)
    WorkingHour.where(inbox_id: inbox_ids).delete_all
    InboxMember.where(inbox_id: inbox_ids).delete_all
    Inbox.where(account_id: account.id).delete_all
    Channel::WebWidget.where(account_id: account.id).delete_all
    NotificationSetting.where(account_id: account.id).delete_all
    AccountUser.where(account_id: account.id).delete_all
    Account.where(id: account.id).delete_all
    User.where(id: user.id).delete_all if user
  end
end
