# frozen_string_literal: true

# An action on many accounts at once, from the account list: apply the plan and its modules, extend the trial, block,
# unblock, link to an organization. It has two steps, and the second does not trust the first:
#
#   bulk = SuperAdmin::BulkAccounts.new(action: 'suspend', ids: ids, actor: current_super_admin, request: request)
#   bulk.preview # what would happen to each account: changed or skipped, and why (nothing is written)
#   bulk.apply   # runs it account by account and tells how many were done and how many skipped (and why)
#
# * `apply` looks at every account again at the moment it is its turn: an account that changed since the confirmation page
#   (someone blocked it, its trial ended) is judged as it is now.
# * An account that fails does not stop the others: it is counted as skipped (`:failed`) and logged.
# * An account that is marked for deletion is never touched; an id that no longer exists is skipped (`:missing`).
# * Every account that is changed leaves ONE entry in the audit log, marked `'bulk' => true`: the same entry the action
#   leaves when it is done from the card of the account (the entry the model writes on a save is left out, so the log does
#   not say the same thing twice).
# * At most LIMIT accounts a time.
#
# What each action does is in SuperAdmin::BulkAccounts::<Action>; they answer `evaluate(account)` and `perform(account)`.
class SuperAdmin::BulkAccounts
  LIMIT = 200
  ACTIONS = %w[apply_plan extend_trial suspend activate link_organization].freeze
  # Written into the audit entry of every account of a bulk action
  AUDIT_EXTRA = { 'bulk' => true }.freeze

  # outcome: :change or :skip; reason: why it is skipped (a key of super_admin.bulk.reasons); detail: what the action
  # shows about the account (it depends on the action)
  Entry = Struct.new(:account_id, :account, :outcome, :reason, :detail, keyword_init: true) do
    def change? = outcome == :change
    def skip? = outcome == :skip
  end

  Preview = Data.define(:entries) do
    def changing = entries.count(&:change?)
    def skipping = entries.count(&:skip?)

    # { reason => number of accounts }, the most frequent first
    def reasons
      entries.select(&:skip?).map(&:reason).tally.sort_by { |reason, count| [-count, reason.to_s] }.to_h
    end
  end

  # done: the number of accounts changed; skipped: { reason => number of accounts }
  Result = Struct.new(:done, :skipped, keyword_init: true) do
    def skipped_total = skipped.values.sum
  end

  # The account ids of a request as a list of numbers without repeats; garbage in the list is dropped. nil when the param
  # is not a list at all (a map, a string).
  def self.parse_ids(raw)
    return [] if raw.nil?
    return unless raw.is_a?(Array)

    raw.filter_map { |value| Integer(value, 10, exception: false) if value.is_a?(String) }.select(&:positive?).uniq
  end

  # ids: the accounts of the request; strategy: what the action does to one account (it knows the setting that was chosen)
  attr_reader :ids, :strategy

  def initialize(action:, ids:, options: {}, actor: nil, request: nil)
    @action = action.to_s
    @ids = ids
    @strategy = strategy_class&.new(options: options, actor: actor, request: request)
  end

  def action_known? = !@strategy.nil?
  def too_many? = ids.size > LIMIT
  def empty? = ids.empty?

  delegate :parameter?, :ready?, :error, :warning?, to: :strategy

  def preview
    Preview.new(entries: ids.map { |id| judge(accounts[id], id) })
  end

  def apply
    result = Result.new(done: 0, skipped: Hash.new(0))
    ids.each do |id|
      reason = apply_one(accounts[id], id)
      reason ? result.skipped[reason] += 1 : result.done += 1
    end
    result
  end

  private

  def strategy_class
    {
      'apply_plan' => SuperAdmin::BulkAccounts::ApplyPlan, 'extend_trial' => SuperAdmin::BulkAccounts::ExtendTrial,
      'suspend' => SuperAdmin::BulkAccounts::Suspend, 'activate' => SuperAdmin::BulkAccounts::Activate,
      'link_organization' => SuperAdmin::BulkAccounts::LinkOrganization
    }[@action]
  end

  # The accounts of the request by id, with their organizations read at once
  def accounts
    @accounts ||= Account.where(id: ids).includes(:organization).index_by(&:id)
  end

  def judge(account, id)
    return Entry.new(account_id: id, account: nil, outcome: :skip, reason: :missing, detail: {}) if account.nil?
    return Entry.new(account_id: id, account: account, outcome: :skip, reason: :deleting, detail: {}) if deleting?(account)

    @strategy.evaluate(account)
  end

  def deleting?(account)
    SuperAdmin::AccountDeletion.new(account: account).scheduled?
  end

  # nil when the account was changed, otherwise why it was not
  def apply_one(account, id)
    entry = judge(account, id)
    return entry.reason if entry.skip?

    Account.without_auditing { @strategy.perform(account) }
  rescue StandardError => e
    Rails.logger.warn("[SuperAdmin] Bulk #{@action} failed for account #{id}: #{e.class.name}: #{e.message}")
    :failed
  end
end
