# frozen_string_literal: true

class Accounts::StorageOverviewService
  REFRESH_INTERVAL = 5.minutes
  PENDING_REFRESH_TTL = 5.minutes
  PENDING_REFRESH_KEY = 'account:%<account_id>s:storage_overview_pending_v2'
  STATEMENT_TIMEOUT = '10s'

  attr_reader :refresh_status

  def self.release_refresh(account_id, job_id)
    Redis::Alfred.delete_if_value(format(PENDING_REFRESH_KEY, account_id: account_id), job_id)
  rescue StandardError => e
    Rails.logger.warn("[StorageOverview] Could not release refresh for account #{account_id}: #{e.class.name}")
  end

  def initialize(account:)
    @account = account
    @refresh_status = 'idle'
  end

  def snapshot
    raw = Redis::Alfred.get(snapshot_cache_key)
    JSON.parse(raw, symbolize_names: true) if raw
  rescue JSON::ParserError
    nil
  end

  def pending?
    Redis::Alfred.exists?(pending_refresh_key)
  end

  def stale?(cached)
    cached.nil? || cached[:generation].to_i != generation || !fresh?(cached)
  end

  def schedule_refresh(force: false)
    cached = snapshot
    if !force && !stale?(cached)
      @refresh_status = pending? ? 'pending' : 'idle'
      return cached
    end

    enqueue_refresh
    cached
  rescue StandardError => e
    @refresh_status = 'failed'
    Rails.logger.warn("[StorageOverview] Could not enqueue refresh for account #{account.id}: #{e.class.name}")
    cached
  end

  # Changes invalidate the generation, preserving the last measured total while a fresh job is pending.
  # A running job may finish, but its pre-change results cannot replace the current snapshot.
  def invalidate!
    Redis::Alfred.incr(generation_key)
    Redis::Alfred.delete(heavy_recordings_cache_key)
    Rails.cache.delete("account:#{account.id}:storage_breakdown_v2")
    Rails.cache.delete(account.local_recordings_bytes_cache_key)
    schedule_refresh(force: true)
  end

  def claim_refresh(job_id)
    renewed = Redis::Alfred.expire_if_value(pending_refresh_key, job_id, PENDING_REFRESH_TTL.to_i)
    [true, 1].include?(renewed) ||
      Redis::Alfred.set(pending_refresh_key, job_id, nx: true, ex: PENDING_REFRESH_TTL.to_i)
  end

  def refresh!(job_id: nil)
    expected_generation = generation
    heartbeat = lease_heartbeat(job_id)
    inventory = Storage::RecordingInventory.new(account: account, heartbeat: heartbeat)
    heavy_recordings = Accounts::HeavyRecordingsSnapshot.new(account_id: account.id)
    with_statement_timeout do
      usage = inventory.calculate
      data = {
        breakdown: account.storage_breakdown(force_refresh: true, heavy_recordings: heavy_recordings, recording_usage: usage),
        limits: AccountLimits::StorageUsageService.new(account: account, recordings_bytes: usage[:total]).summary,
        recording_total_bytes: usage[:total], generation: expected_generation, updated_at: Time.current.to_i
      }
      return unless publish_snapshot(data, heavy_recordings, job_id)

      inventory.publish!
      Rails.cache.write(account.local_recordings_bytes_cache_key, usage[:total], expires_in: 10.minutes)
      Rails.cache.write(account.local_recordings_last_good_cache_key, usage[:total], expires_in: 7.days)
      data
    end
  end

  private

  attr_reader :account

  # No transaction surrounds the background file reconciliation. Production closes idle transactions at 60s.
  # Every database statement is limited to ten seconds and the pooled session setting is restored on failure.
  def with_statement_timeout
    connection = ActiveRecord::Base.connection
    previous_timeout = connection.select_value('SHOW statement_timeout')
    connection.execute("SET statement_timeout = '#{STATEMENT_TIMEOUT}'")
    yield
  ensure
    restore_statement_timeout(connection, previous_timeout)
  end

  def restore_statement_timeout(connection, previous_timeout)
    return if connection.nil? || previous_timeout.nil?

    connection.execute(ActiveRecord::Base.sanitize_sql_array(['SELECT set_config(?, ?, false)', 'statement_timeout', previous_timeout]))
  rescue StandardError => e
    Rails.logger.warn("[StorageOverview] Could not restore statement_timeout: #{e.class.name}")
  end

  def fresh?(cached)
    cached && Time.current.to_i - cached[:updated_at].to_i < REFRESH_INTERVAL.to_i
  end

  def enqueue_refresh
    job = Accounts::StorageBreakdownRefreshJob.new(account.id)
    unless Redis::Alfred.set(pending_refresh_key, job.job_id, nx: true, ex: PENDING_REFRESH_TTL.to_i)
      @refresh_status = 'pending'
      return
    end

    job.enqueue
    raise "Could not enqueue storage refresh for account #{account.id}" unless job.successfully_enqueued?

    @refresh_status = 'queued'
  rescue StandardError
    Redis::Alfred.delete_if_value(pending_refresh_key, job.job_id) if job
    raise
  end

  def lease_heartbeat(job_id)
    return unless job_id

    renewed_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    lambda do
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      next if now - renewed_at < 30

      renewed = Redis::Alfred.expire_if_value(pending_refresh_key, job_id, PENDING_REFRESH_TTL.to_i)
      raise 'Storage refresh lease lost' unless [true, 1].include?(renewed)

      renewed_at = now
    end
  end

  def publish_snapshot(data, heavy_recordings, job_id)
    keys = [generation_key, pending_refresh_key, snapshot_cache_key, heavy_recordings_cache_key]
    values = [data[:generation].to_s, job_id.to_s, JSON.generate(data), heavy_recordings.payload]
    Redis::Alfred.publish_storage_snapshot(keys, values).to_i.positive?
  end

  def generation
    Redis::Alfred.get(generation_key).to_i
  end

  def generation_key
    "account:#{account.id}:storage_generation_v1"
  end

  def snapshot_cache_key
    "account:#{account.id}:storage_overview_v1"
  end

  def heavy_recordings_cache_key
    "account:#{account.id}:storage_heavy_recordings_v1"
  end

  def pending_refresh_key
    format(PENDING_REFRESH_KEY, account_id: account.id)
  end
end
