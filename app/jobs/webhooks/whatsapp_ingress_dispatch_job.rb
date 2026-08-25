class Webhooks::WhatsappIngressDispatchJob < ApplicationJob
  queue_as :whatsapp_inbound
  retry_on Whatsapp::WabaLock::LockAcquisitionError, wait: 1.second, attempts: :unlimited

  def self.perform_later!(*)
    job = perform_later(*)
    return job if job.successfully_enqueued?

    raise job.enqueue_error || ActiveJob::EnqueueError.new('WhatsApp ingress deferral was not enqueued')
  end

  def perform(payload, central_ingress, default_callback, verification_context)
    verification_context = verification_context.to_h.with_indifferent_access

    Whatsapp::WebhookIngressDispatcher.new(
      payload: payload,
      central_ingress: central_ingress,
      default_callback: default_callback,
      verification_context: ->(_atomic_payload) { verification_context }
    ).perform_normalized
  end
end
