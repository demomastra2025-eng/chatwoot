require 'digest'

class Integrations::Macrocrm::ManagerChangedJob < MutexApplicationJob
  queue_as :medium
  LOCK_TIMEOUT = 30.seconds

  retry_on LockAcquisitionError, wait: 5.seconds, attempts: 12
  retry_on StandardError, wait: 10.seconds, attempts: 3
  discard_on ActiveRecord::RecordNotFound

  def perform(hook_id, payload)
    normalized_payload = payload.deep_stringify_keys

    with_lock(lock_key(hook_id, lock_scope(normalized_payload)), LOCK_TIMEOUT) do
      hook = Integrations::Hook.find(hook_id)

      Integrations::Macrocrm::ManagerChangedProcessorService.new(
        hook: hook,
        payload: normalized_payload
      ).perform
    end
  end

  private

  def lock_key(hook_id, estate_id)
    format(::Redis::Alfred::MACROCRM_MANAGER_CHANGED_MUTEX, hook_id: hook_id, estate_id: estate_id)
  end

  def lock_scope(payload)
    estate_id = payload.dig('data', 'object', 'estate_id').presence
    return estate_id if estate_id.present?

    webhook_phone = payload.dig('data', 'object', 'client_phones').to_s.gsub(/\s+/, '')
    return "phone-#{webhook_phone}" if webhook_phone.present?

    "payload-#{Digest::SHA256.hexdigest(payload.to_json).first(12)}"
  end
end
