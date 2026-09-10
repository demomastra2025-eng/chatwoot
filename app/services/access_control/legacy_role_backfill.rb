class AccessControl::LegacyRoleBackfill
  class ParityMismatch < StandardError; end

  AccountResult = Data.define(:account_id, :assignment_counts, :compatibility_counts, :entries, :error)
  Summary = Data.define(:apply, :processed_accounts, :failed_accounts, :assignment_counts, :compatibility_counts)

  def self.call(accounts: Account.all, apply: false, batch_size: 100, &)
    new(accounts, apply: apply, batch_size: batch_size).call(&)
  end

  def initialize(accounts, apply:, batch_size:)
    raise ArgumentError, 'batch_size must be positive' unless batch_size.to_i.positive?

    @accounts = accounts
    @apply = apply
    @batch_size = batch_size.to_i
    @processed_accounts = 0
    @failed_accounts = 0
    @assignment_counts = Hash.new(0)
    @compatibility_counts = Hash.new(0)
  end

  def call
    accounts.find_each(batch_size: batch_size) do |account|
      result = process_account(account)
      yield result if block_given?
    end

    Summary.new(
      apply: apply,
      processed_accounts: processed_accounts,
      failed_accounts: failed_accounts,
      assignment_counts: assignment_counts.sort.to_h,
      compatibility_counts: compatibility_counts.sort.to_h
    )
  end

  private

  attr_reader :accounts, :apply, :batch_size, :processed_accounts, :failed_accounts,
              :assignment_counts, :compatibility_counts

  def process_account(account)
    @processed_accounts += 1
    assignment, compatibility = run_account(account)
    merge_counts!(assignment_counts, assignment.counts)
    merge_counts!(compatibility_counts, compatibility.counts)
    successful_result(account, assignment, compatibility)
  rescue StandardError => e
    @failed_accounts += 1
    failed_result(account, e)
  end

  def run_account(account)
    Account.transaction(requires_new: true) do
      assignment = AccessControl::LegacyRoleAssigner.call(account: account, apply: apply)
      compatibility = AccessControl::LegacyCompatibilityChecker.call(account: account)
      verify_parity!(compatibility)
      [assignment, compatibility]
    end
  end

  def verify_parity!(compatibility)
    return unless apply && compatibility.counts.fetch('mismatch', 0).positive?

    raise ParityMismatch, 'AccessRole backfill did not reach parity'
  end

  def successful_result(account, assignment, compatibility)
    AccountResult.new(
      account_id: account.id,
      assignment_counts: assignment.counts,
      compatibility_counts: compatibility.counts,
      entries: compatibility.entries.map(&:to_h),
      error: nil
    )
  end

  def failed_result(account, error)
    AccountResult.new(
      account_id: account.id,
      assignment_counts: {},
      compatibility_counts: {},
      entries: [],
      error: error.class.name
    )
  end

  def merge_counts!(totals, counts)
    counts.each { |status, count| totals[status] += count }
  end
end
