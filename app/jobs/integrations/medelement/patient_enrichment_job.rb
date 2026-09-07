class Integrations::Medelement::PatientEnrichmentJob < MutexApplicationJob
  queue_as :medelement_sync

  LOCK_TIMEOUT = 1.minute
  QUEUED_LEASE_TTL = 6.hours.to_i

  retry_on LockAcquisitionError, wait: 10.seconds, attempts: 3
  retry_on Integrations::Medelement::Client::ApiError, wait: 1.minute, attempts: 3
  discard_on ActiveRecord::RecordNotFound

  class << self
    def enqueue(hook_id, contact_id)
      dedup_token = SecureRandom.uuid
      key = queued_key(hook_id, contact_id)
      claimed = Redis::Alfred.set(key, dedup_token, nx: true, ex: QUEUED_LEASE_TTL)
      return false if claimed.blank?

      job = perform_later(hook_id, contact_id, dedup_token)
      unless job.respond_to?(:successfully_enqueued?) && job.successfully_enqueued?
        enqueue_error = job.enqueue_error if job.respond_to?(:enqueue_error)
        raise enqueue_error || ActiveJob::EnqueueError.new('Failed to enqueue Medelement patient enrichment')
      end

      true
    rescue StandardError
      safely_release_queued_lease(key, dedup_token)
      raise
    end

    def queued_key(hook_id, contact_id)
      format(
        Redis::Alfred::MEDELEMENT_PATIENT_ENRICHMENT_QUEUED,
        hook_id: hook_id,
        contact_id: contact_id
      )
    end

    def safely_release_queued_lease(key, dedup_token)
      return if key.blank? || dedup_token.blank?

      Redis::Alfred.delete_if_value(key, dedup_token)
    rescue StandardError => e
      Rails.logger.error("Failed to release Medelement patient enrichment enqueue lease: #{e.class}: #{e.message}")
    end
  end

  def perform(hook_id, contact_id, dedup_token = nil)
    release_queued_lease(hook_id, contact_id, dedup_token)
    hook = Integrations::Hook.find(hook_id)
    return unless enrichment_enabled?(hook)

    contact = hook.account.contacts.find(contact_id)
    return if Integrations::Medelement::PhoneNumber.normalize(contact.phone_number).blank?

    with_lock(lock_key(hook.id, contact.id), LOCK_TIMEOUT) do
      Integrations::Medelement::PatientEnrichmentService.new(hook: hook).perform(contact.reload)
    end
  rescue Integrations::Medelement::Client::ApiError => e
    raise if e.retryable?

    Rails.logger.warn("Medelement patient enrichment rejected with HTTP #{e.status}")
  end

  private

  def release_queued_lease(hook_id, contact_id, dedup_token)
    return if dedup_token.blank?

    Redis::Alfred.delete_if_value(self.class.queued_key(hook_id, contact_id), dedup_token)
  end

  def enrichment_enabled?(hook)
    hook.medelement? && hook.enabled? && hook.feature_allowed? &&
      Integrations::Medelement::Configuration.new(hook: hook).sync_patients?
  end

  def lock_key(hook_id, contact_id)
    format(
      Redis::Alfred::MEDELEMENT_PATIENT_ENRICHMENT_MUTEX,
      hook_id: hook_id,
      contact_id: contact_id
    )
  end
end
