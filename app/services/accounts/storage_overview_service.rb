# frozen_string_literal: true

class Accounts::StorageOverviewService
  REFRESH_INTERVAL = 5.minutes
  STATEMENT_TIMEOUT = '10s'

  def initialize(account:)
    @account = account
  end

  def snapshot
    raw = Redis::Alfred.get(snapshot_cache_key)
    JSON.parse(raw, symbolize_names: true) if raw
  rescue JSON::ParserError
    nil
  end

  def schedule_refresh(force: false)
    cached = snapshot
    return cached if !force && fresh?(cached)

    enqueue_refresh
    cached
  rescue StandardError => e
    Rails.logger.warn("[StorageOverview] Could not enqueue refresh for account #{account.id}: #{e.class.name}")
    cached
  end

  def refresh!
    data = ActiveRecord::Base.transaction(requires_new: true) do
      connection = ActiveRecord::Base.connection
      previous_timeout = connection.select_value('SHOW statement_timeout')
      connection.execute("SET LOCAL statement_timeout = '#{STATEMENT_TIMEOUT}'")
      result = {
        breakdown: account.storage_breakdown(force_refresh: true),
        limits: AccountLimits::StorageUsageService.new(account: account).summary,
        updated_at: Time.current.to_i
      }
      connection.execute(ActiveRecord::Base.sanitize_sql_array(['SELECT set_config(?, ?, true)', 'statement_timeout', previous_timeout]))
      result
    end
    Redis::Alfred.set(snapshot_cache_key, JSON.generate(data))
    data
  end

  private

  attr_reader :account

  def fresh?(cached)
    cached && Time.current.to_i - cached[:updated_at] < REFRESH_INTERVAL.to_i
  end

  def enqueue_refresh
    lock_token = SecureRandom.uuid
    return unless Redis::Alfred.set(refresh_cache_key, lock_token, nx: true, ex: REFRESH_INTERVAL.to_i)

    Accounts::StorageBreakdownRefreshJob.perform_later(account.id)
  rescue StandardError
    Redis::Alfred.delete_if_value(refresh_cache_key, lock_token) if lock_token
    raise
  end

  def snapshot_cache_key
    "account:#{account.id}:storage_overview_v1"
  end

  def refresh_cache_key
    "account:#{account.id}:storage_overview_refresh_v1"
  end
end
