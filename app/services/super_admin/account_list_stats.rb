# frozen_string_literal: true

# The numbers of one page of the clinic list: plan chips, operators used / limit, storage fill, channel count, status.
#
# Everything is read for the whole page at once (grouped counts, ONE Redis MGET for the storage snapshots), so a page
# of 20 clinics costs the same number of queries and Redis calls as a page of 2. Storage comes from the hourly snapshot
# (Accounts::StorageOverviewService#snapshot): the list never measures disks and never queues a refresh.
#
#   stats = SuperAdmin::AccountListStats.new(accounts)
#   row = stats.for(account)
#   row.plan.chips, row.operators_used, row.operators_limit, row.storage, row.channels, row.status
class SuperAdmin::AccountListStats
  Storage = Struct.new(:consumed, :total, :unlimited, :percent, :tone, keyword_init: true)
  Row = Struct.new(:plan, :operators_used, :operators_limit, :storage, :channels, :status, keyword_init: true) do
    # No limit at all, or the "no limit" a plan writes (ChatwootApp.max_limit)
    def operators_unlimited?
      operators_limit.nil? || operators_limit >= ChatwootApp.max_limit.to_i
    end
  end

  def initialize(accounts)
    @accounts = accounts.to_a
    ids = @accounts.map(&:id)
    @member_counts = AccountUser.where(account_id: ids).group(:account_id).count
    @channel_counts = Inbox.where(account_id: ids).group(:account_id).count
    @excluded_counts = excluded_member_counts
    @global_agent_limit = GlobalConfig.get('ACCOUNT_AGENTS_LIMIT')['ACCOUNT_AGENTS_LIMIT']
  end

  def for(account)
    plan = SuperAdmin::AccountPlanState.new(account)
    Row.new(
      plan: plan,
      operators_used: operators_used(account),
      operators_limit: operators_limit(account),
      storage: storage(account),
      channels: channels(account),
      status: plan.status
    )
  end

  # Members of the clinic that the operator limit counts
  def operators_used(account)
    @member_counts.fetch(account.id, 0) - @excluded_counts.fetch(account.id, 0)
  end

  # Inboxes (channels) of the clinic
  def channels(account)
    @channel_counts.fetch(account.id, 0)
  end

  # The same answer as Account#agent_limit_metadata (a spec compares them), without a config read per clinic.
  # nil means no limit.
  def operators_limit(account)
    quantity = account.custom_attributes.to_h['subscribed_quantity']
    return quantity.to_i if quantity.present?

    own = account.limits.to_h['agents']
    return own.to_i if own.present?

    @global_agent_limit.to_i if @global_agent_limit.present?
  end

  private

  # Members that the limit does not count (custom_attributes limit_counter_excluded_user_ids), per clinic.
  # One query, and only when some clinic of the page has such a list.
  def excluded_member_counts
    excluded = @accounts.select { |account| account.respond_to?(:limit_counter_excluded_user_ids) }
                        .to_h { |account| [account.id, account.limit_counter_excluded_user_ids] }
                        .reject { |_id, user_ids| user_ids.empty? }
    return {} if excluded.empty?

    AccountUser.where(account_id: excluded.keys).pluck(:account_id, :user_id).each_with_object(Hash.new(0)) do |(account_id, user_id), counts|
      counts[account_id] += 1 if excluded[account_id].include?(user_id)
    end
  end

  # The hourly snapshots of the page, read with one MGET the first time a row asks for the storage (the organization
  # pages only need the counts and never pay for it)
  def storage_snapshots
    @storage_snapshots ||= Accounts::StorageOverviewService.snapshots_for(@accounts)
  end

  def storage(account)
    summary = storage_snapshots[account.id]&.dig(:limits)
    return if summary.blank?

    unlimited = summary[:unlimited] ? true : false
    total = summary[:total_count].to_i
    consumed = summary[:consumed].to_i
    percent = (consumed.to_f / total * 100).round(1) unless unlimited || total <= 0
    Storage.new(consumed: consumed, total: total, unlimited: unlimited, percent: percent, tone: storage_tone(percent, unlimited))
  end

  def storage_tone(percent, unlimited)
    return :idle if unlimited || percent.nil?
    return :bad if percent >= SuperAdmin::AccountUsage::CRITICAL_PERCENT
    return :warn if percent >= SuperAdmin::AccountUsage::WARNING_PERCENT

    :good
  end
end
