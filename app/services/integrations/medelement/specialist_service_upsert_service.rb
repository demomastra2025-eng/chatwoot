class Integrations::Medelement::SpecialistServiceUpsertService
  def initialize(account:, payload:, services_by_code:, conflict_tracker: nil)
    @account = account
    @payload = payload.to_h.with_indifferent_access
    @services_by_code = services_by_code
    @conflict_tracker = conflict_tracker
  end

  def perform
    return log_skipped('unknown_specialist') if resource.blank?
    return log_skipped('unknown_service') if service.blank?
    return log_skipped('active_price_must_be_non_negative') if active? && price.to_i.negative?

    service_price = service.prices.find_or_initialize_by(resource: resource)
    service_price.assign_attributes(price_attributes(service_price))
    service_price.save!
    true
  rescue ArgumentError => e
    log_skipped(e.message)
  end

  private

  attr_reader :account, :conflict_tracker, :payload, :services_by_code

  def active?
    return true unless payload.key?('active')

    ActiveModel::Type::Boolean.new.cast(payload['active'])
  end

  def price
    @price ||= normalized_integer(payload['price'].presence || service&.base_price, :price)
  end

  def price_attributes(service_price)
    {
      account: account,
      price: price.to_i,
      active: active?,
      compensation_type: compensation_type(service_price),
      compensation_value: compensation_value(service_price),
      compensation_percent: compensation_percent(service_price)
    }
  end

  def compensation_type(service_price)
    payload['compensationType'].presence || service_price.compensation_type || 'percent'
  end

  def compensation_value(service_price)
    return service_price.compensation_value || 0 unless payload.key?('compensationValue')

    normalized_integer(payload['compensationValue'], :compensation_value) || 0
  end

  def compensation_percent(service_price)
    return service_price.compensation_percent || 0 unless payload.key?('compensationPercent')

    normalized_integer(payload['compensationPercent'], :compensation_percent) || 0
  end

  def normalized_integer(value, field_name)
    return if value.blank?

    Scheduling::IntegerNumericNormalizer.normalize(value, field_name: field_name)
  end

  def specialist_code
    payload['specialistCode'].to_s
  end

  def service_code
    payload['serviceCode'].to_s
  end

  def resource
    @resource ||= account.scheduling_resources.find_by(
      "custom_attributes ->> '#{Integrations::Medelement::SpecialistsSyncService::SPECIALIST_CODE_KEY}' = ?",
      specialist_code
    )
  end

  def service
    @service ||= services_by_code[service_code] || account.scheduling_services.find_by(
      "custom_attributes ->> '#{Integrations::Medelement::ServicesSyncService::EXTERNAL_CODE_KEY}' = ?",
      service_code
    )
  end

  def log_skipped(reason)
    entity_key = [specialist_code.presence || 'missing', service_code.presence || 'missing'].join(':')
    conflict_tracker&.record!(
      phase: 'services',
      entity_type: 'specialist_service',
      conflict_type: 'invalid_specialist_service',
      entity_key: entity_key,
      severity: 'error',
      details: conflict_details(reason)
    )
    Rails.logger.warn(
      "[MEDELEMENT::SERVICES_SYNC] Skipping specialist service for account=#{account.id} " \
      "entity_digest=#{Integrations::Medelement::ErrorSanitizer.digest(entity_key)} reason=#{reason}"
    )
    false
  end

  def conflict_details(reason)
    {
      reason: reason,
      specialist_code: specialist_code.presence,
      service_code: service_code.presence,
      resource_id: resource&.id,
      service_id: service&.id
    }.compact
  end
end
