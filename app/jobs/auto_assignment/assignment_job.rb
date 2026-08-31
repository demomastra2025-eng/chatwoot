class AutoAssignment::AssignmentJob < ApplicationJob
  queue_as :auto_assignment

  QUEUED_LEASE_TTL = 1.hour.to_i
  RUNNING_LEASE_TTL = 30.minutes.to_i
  LEGACY_DRAIN_LEASE_TTL = 1.hour.to_i
  OVERLAP_RETRY_DELAY = 15.seconds

  class << self
    def enqueue(inbox_id:, wait: nil)
      dedup_token = SecureRandom.uuid
      key = queued_key(inbox_id)
      claimed = Redis::Alfred.set(key, dedup_token, nx: true, ex: QUEUED_LEASE_TTL)
      return false if claimed.blank?

      job = wait.present? ? set(wait: wait) : self
      enqueued_job = job.perform_later(inbox_id: inbox_id, dedup_token: dedup_token)
      raise ActiveJob::EnqueueError, "Failed to enqueue auto assignment for inbox #{inbox_id}" if enqueued_job.blank?

      true
    rescue StandardError
      safely_release_queued_lease(key, dedup_token)
      raise
    end

    def safely_release_queued_lease(key, dedup_token)
      return if key.blank? || dedup_token.blank?

      Redis::Alfred.delete_if_value(key, dedup_token)
    rescue StandardError => e
      Rails.logger.error("Failed to release auto assignment enqueue lease #{key}: #{e.class}: #{e.message}")
    end

    def queued_key(inbox_id)
      format(Redis::Alfred::AUTO_ASSIGNMENT_JOB_QUEUED, inbox_id: inbox_id)
    end

    def running_key(inbox_id)
      format(Redis::Alfred::AUTO_ASSIGNMENT_JOB_RUNNING, inbox_id: inbox_id)
    end

    def legacy_drain_key(inbox_id)
      format(Redis::Alfred::AUTO_ASSIGNMENT_LEGACY_DRAIN, inbox_id: inbox_id)
    end
  end

  def perform(inbox_id:, dedup_token: nil)
    initialize_execution(inbox_id, dedup_token)
    return unless claim_legacy_payload
    return defer_for_running_job unless claim_running_lease

    release_queued_lease
    run_assignment
  rescue StandardError => e
    release_legacy_lease
    Rails.logger.error "Bulk assignment failed for inbox #{inbox_id}: #{e.message}"
    raise
  ensure
    release_running_lease
  end

  private

  def initialize_execution(inbox_id, dedup_token)
    @inbox_id = inbox_id
    @dedup_token = dedup_token
    @legacy_claimed = false
    @running_claimed = false
  end

  def claim_legacy_payload
    return true if @dedup_token.present?

    @legacy_token = SecureRandom.uuid
    @legacy_claimed = Redis::Alfred.set(
      self.class.legacy_drain_key(@inbox_id),
      @legacy_token,
      nx: true,
      ex: LEGACY_DRAIN_LEASE_TTL
    ).present?
  end

  def claim_running_lease
    @running_token = SecureRandom.uuid
    @running_key = self.class.running_key(@inbox_id)
    @running_claimed = Redis::Alfred.set(
      @running_key,
      @running_token,
      nx: true,
      ex: RUNNING_LEASE_TTL
    ).present?
  end

  def defer_for_running_job
    release_queued_lease
    self.class.enqueue(inbox_id: @inbox_id, wait: OVERLAP_RETRY_DELAY)
  end

  def release_queued_lease
    return if @dedup_token.blank?

    Redis::Alfred.delete_if_value(self.class.queued_key(@inbox_id), @dedup_token)
  end

  def run_assignment
    inbox = Inbox.find_by(id: @inbox_id)
    return if inbox.blank?

    assigned_count = AutoAssignment::AssignmentService.new(inbox: inbox)
                                                      .perform_bulk_assignment(limit: bulk_assignment_limit)
    Rails.logger.info "Assigned #{assigned_count} conversations for inbox #{inbox.id}"
    self.class.enqueue(inbox_id: inbox.id) if assigned_count >= bulk_assignment_limit
  end

  def release_legacy_lease
    return unless @legacy_claimed

    Redis::Alfred.delete_if_value(self.class.legacy_drain_key(@inbox_id), @legacy_token)
  end

  def release_running_lease
    return unless @running_claimed

    Redis::Alfred.delete_if_value(@running_key, @running_token)
  end

  def bulk_assignment_limit
    ENV.fetch('AUTO_ASSIGNMENT_BULK_LIMIT', 100).to_i
  end
end
