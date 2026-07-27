class Integrations::Medelement::PatientEnrichmentJob < MutexApplicationJob
  queue_as :medium

  LOCK_TIMEOUT = 1.minute

  retry_on LockAcquisitionError, wait: 10.seconds, attempts: 3
  retry_on Integrations::Medelement::Client::ApiError, wait: 1.minute, attempts: 3
  discard_on ActiveRecord::RecordNotFound

  def perform(hook_id, contact_id)
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
