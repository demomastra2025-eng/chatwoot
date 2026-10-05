# One-off, repeatable repair of catalog rows that still carry the English names
# the first release seeded (see Crm::TaskCatalogs::SeedNames). Only rows of a
# system code whose name is still exactly the old default are renamed to the
# neutral name in the account language; a name an admin edited is never touched.
#
# Works in small batches of accounts with one narrow UPDATE per rename, so it is
# safe to run on a live database. With a lock_timeout (the rake task) every
# UPDATE runs in its own short transaction and is retried when a row is busy;
# without one (the provisioner, already inside a transaction) it just updates.
class Crm::TaskCatalogs::NameRepair
  BATCH_SIZE = 200
  MAX_ATTEMPTS = 3

  def initialize(accounts: Account.all, lock_timeout: nil, batch_size: BATCH_SIZE)
    @accounts = accounts
    @lock_timeout = lock_timeout
    @batch_size = batch_size
  end

  # Returns the number of renamed rows.
  def perform
    renamed = 0
    accounts.in_batches(of: batch_size) do |batch|
      batch.pluck(:id, :locale).group_by { |_id, locale| Crm::TaskCatalogs::SeedNames.locale_for(locale) }.each do |locale, rows|
        renamed += repair_accounts(rows.map(&:first), locale)
      end
    end
    renamed
  end

  private

  attr_reader :accounts, :lock_timeout, :batch_size

  def repair_accounts(account_ids, locale)
    Crm::TaskCatalogs::SeedNames.renames(locale).sum do |rename|
      guarded { rename_rows(account_ids, rename) }
    end
  end

  def rename_rows(account_ids, rename)
    scope =
      case rename[:kind]
      when :type then Crm::TaskType.where(account_id: account_ids, code: rename[:code])
      when :status then Crm::TaskStatus.where(account_id: account_ids, code: rename[:code])
      else outcome_scope(account_ids, rename)
      end

    scope.where(name: rename[:from]).update_all(name: rename[:to], updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
  end

  def outcome_scope(account_ids, rename)
    type_ids = Crm::TaskType.where(account_id: account_ids, code: rename[:type_code]).select(:id)
    Crm::TaskOutcome.where(account_id: account_ids, task_type_id: type_ids, code: rename[:code])
  end

  def guarded
    return yield if lock_timeout.blank?

    attempts = 0
    begin
      attempts += 1
      ApplicationRecord.transaction do
        ApplicationRecord.connection.execute("SET LOCAL lock_timeout = #{ApplicationRecord.connection.quote(lock_timeout)}")
        yield
      end
    rescue ActiveRecord::LockWaitTimeout
      raise if attempts >= MAX_ATTEMPTS

      sleep(0.5 * attempts)
      retry
    end
  end
end
