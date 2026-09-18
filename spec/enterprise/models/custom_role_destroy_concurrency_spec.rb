require 'rails_helper'
require 'timeout'

RSpec.describe CustomRole, '#destroy concurrency' do
  self.use_transactional_tests = false

  %i[account_user lifecycle_snapshot].each do |subject_type|
    it "rejects deletion after a concurrent legacy-only #{subject_type} assignment" do
      account = create(:account)
      user = create(:user)
      custom_role = create(:custom_role, account: account, permissions: %w[crm_task_view])
      mapped_role = AccessControl::LegacyCustomRoleMapper.call(custom_role: custom_role)
      custom_role.update!(permissions: %w[report_manage])
      result = exercise_locked_writer_interleaving(subject_type, account: account, user: user, custom_role: custom_role)

      expect(result).to include(destroyed: false)
      expect(result.fetch(:errors)).to be_present
      expect(described_class.where(id: custom_role.id)).to exist
      expect(AccessRole.where(id: mapped_role.id)).to exist
      expect(legacy_subject_scope(subject_type, account.id, custom_role.id)).to exist
    ensure
      cleanup_records(account, user)
    end
  end

  def exercise_locked_writer_interleaving(subject_type, account:, user:, custom_role:)
    queues = %i[writer_locked release_writer writer_finished destroy_lock_attempted destroy_finished].index_with { Queue.new }
    records = { account: account, user: user, custom_role: custom_role }
    writer = start_writer(subject_type, records, queues)
    assert_writer_started(queues)
    destroyer = start_destroyer(custom_role.id, queues)
    assert_destroy_waits_for_lock(queues)
    finish_interleaving(queues)
  ensure
    queues&.fetch(:release_writer)&.push(true)
    stop_thread(writer)
    stop_thread(destroyer)
  end

  def start_writer(subject_type, records, queues)
    Thread.new do
      startup_signalled = false
      ActiveRecord::Base.connection_pool.with_connection do
        Account.transaction do
          locked_account = Account.lock.find(records.fetch(:account).id)
          queues.fetch(:writer_locked) << true
          startup_signalled = true
          queues.fetch(:release_writer).pop
          role = described_class.find(records.fetch(:custom_role).id)
          create_legacy_only_subject(subject_type, account: locked_account, user: records.fetch(:user), custom_role: role)
        end
        queues.fetch(:writer_finished) << true
      rescue StandardError => e
        queues.fetch(:writer_locked) << e unless startup_signalled
        queues.fetch(:writer_finished) << e
      end
    end
  end

  def start_destroyer(custom_role_id, queues)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        role = described_class.find(custom_role_id)
        original_lock = role.method(:lock_account_for_access_control)
        role.define_singleton_method(:lock_account_for_access_control) do
          queues.fetch(:destroy_lock_attempted) << true
          original_lock.call
        end
        role.destroy
        queues.fetch(:destroy_finished) << { destroyed: role.destroyed?, errors: role.errors.full_messages }
      rescue StandardError => e
        queues.fetch(:destroy_finished) << e
      end
    end
  end

  def assert_writer_started(queues)
    result = Timeout.timeout(3) { queues.fetch(:writer_locked).pop }
    raise result if result.is_a?(StandardError)
  end

  def assert_destroy_waits_for_lock(queues)
    Timeout.timeout(3) { queues.fetch(:destroy_lock_attempted).pop }
    expect { Timeout.timeout(0.2) { queues.fetch(:destroy_finished).pop } }.to raise_error(Timeout::Error)
  end

  def finish_interleaving(queues)
    queues.fetch(:release_writer) << true
    writer_result = Timeout.timeout(3) { queues.fetch(:writer_finished).pop }
    raise writer_result if writer_result.is_a?(StandardError)

    Timeout.timeout(3) { queues.fetch(:destroy_finished).pop }
  end

  def create_legacy_only_subject(subject_type, account:, user:, custom_role:)
    attributes = { account: account, user: user, custom_role: custom_role, access_role: nil }
    return AccountUser.create!(attributes) if subject_type == :account_user

    create(:account_user_lifecycle_snapshot, **attributes)
  end

  def legacy_subject_scope(subject_type, account_id, custom_role_id)
    model = subject_type == :account_user ? AccountUser : AccountUserLifecycleSnapshot
    model.where(account_id: account_id, custom_role_id: custom_role_id, access_role_id: nil)
  end

  def cleanup_records(account, user)
    return unless account

    AccountUserLifecycleSnapshot.where(account_id: account.id).delete_all
    AccountUser.where(account_id: account.id).delete_all
    AccessRoleGrant.where(account_id: account.id).delete_all
    AccessRole.where(account_id: account.id).delete_all
    CustomRole.where(account_id: account.id).delete_all
    Account.where(id: account.id).delete_all
    User.where(id: user&.id).delete_all
  end

  def stop_thread(thread)
    return unless thread

    thread.kill unless thread.join(3)
    thread.join
  end
end
