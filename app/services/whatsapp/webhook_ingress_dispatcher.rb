class Whatsapp::WebhookIngressDispatcher
  def initialize(payload:, central_ingress:, default_callback:, verification_context:)
    @payload = payload.to_h.with_indifferent_access
    @central_ingress = central_ingress
    @default_callback = default_callback
    @verification_context = verification_context
  end

  def perform
    job_payloads.each { |payload| dispatch(payload) }
  end

  private

  def dispatch(payload)
    waba_id = payload.dig(:entry, 0, :id).to_s.presence
    return dispatch_to_destinations(payload) if waba_id.blank?

    Whatsapp::WabaLock.new(waba_id).with_lock do
      payload = with_legacy_account_update_route(payload)
      WhatsappWebhookRoute.with_waba_registry_lock(waba_id) { dispatch_to_destinations(payload) }
    end
  end

  def dispatch_to_destinations(payload)
    destinations_for(payload).each do |destination|
      if destination == Whatsapp::WebhookIngressRouter::LOCAL_DESTINATION
        Webhooks::WhatsappEventsJob.perform_later(payload, @verification_context.call(payload))
      else
        Webhooks::WhatsappForwardJob.perform_later(payload, destination)
      end
    end
  end

  def destinations_for(payload)
    return [Whatsapp::WebhookIngressRouter::LOCAL_DESTINATION] unless @central_ingress

    Whatsapp::WebhookIngressRouter.new(payload: payload).destinations
  end

  def job_payloads
    should_normalize = @central_ingress || (@default_callback && account_update_webhook?)
    return [@payload] unless should_normalize

    Whatsapp::WebhookBatchNormalizer.new(params: @payload).perform
  end

  def account_update_webhook?
    webhook_changes.any? { |change| change[:field] == 'account_update' }
  end

  def with_legacy_account_update_route(payload)
    return payload unless payload.dig(:entry, 0, :changes, 0, :field) == 'account_update'

    waba_id = payload.dig(:entry, 0, :id).to_s
    owner_account_id = Channel::Whatsapp.unambiguous_waba_owner_account_id(waba_id)
    return payload if waba_id.blank? || owner_account_id.blank?

    route_phone = Channel::Whatsapp.lifecycle_cloud.for_waba(waba_id).where(account_id: owner_account_id).order(:id).pick(:phone_number)
    route_phone.present? ? payload.merge(phone_number: route_phone) : payload
  end

  def webhook_changes
    Array(@payload[:entry]).flat_map do |entry|
      Array(entry.to_h.with_indifferent_access[:changes]).map { |change| change.to_h.with_indifferent_access }
    end
  end
end
