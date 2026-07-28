class Integrations::Medelement::ServiceUpsertService
  def initialize(account:, payload:, now:)
    @account = account
    @payload = payload.to_h.with_indifferent_access
    @now = now
  end

  def perform
    return log_skipped('missing_service_code') if code.blank?
    return log_skipped('missing_name') if name.blank?

    service = find_service || account.scheduling_services.new
    assign_required_attributes(service)
    assign_optional_attributes(service)
    service.save!
    service
  rescue ArgumentError => e
    log_skipped(e.message)
  end

  private

  attr_reader :account, :now, :payload

  def assign_required_attributes(service)
    service.assign_attributes(
      account: service.account || account,
      name: name,
      active: source_active?,
      custom_attributes: service.custom_attributes.merge(custom_attributes)
    )
  end

  def assign_optional_attributes(service)
    assign_present_attribute(service, :base_price, normalized_integer(source_price, :price))
    assign_present_attribute(service, :duration_min, normalized_duration)
    assign_present_attribute(service, :category, payload['category'].presence || payload['PARENT_NAME'].presence)
    assign_present_attribute(service, :direction, payload['direction'].presence)
    assign_present_attribute(service, :service_type, payload['serviceType'].presence || payload['NOMENCLATURE_TYPE_CODE'].presence)
  end

  def assign_present_attribute(record, attribute, value)
    record.public_send("#{attribute}=", value) unless value.nil?
  end

  def code
    @code ||= payload['serviceCode'].presence || payload['NOMENCLATURE_CODE'].presence
  end

  def name
    @name ||= payload['name'].presence || payload['NOMENCLATURE_NAME'].presence
  end

  def find_service
    account.scheduling_services.find_by(
      "custom_attributes ->> '#{Integrations::Medelement::ServicesSyncService::EXTERNAL_CODE_KEY}' = ?",
      code.to_s
    )
  end

  def normalized_duration
    value = payload['durationMin'].presence || payload['duration_min'].presence
    return if value.blank?

    duration = normalized_integer(value, :duration_min)
    raise ArgumentError, 'duration_min is outside 5..720' unless duration.between?(5, 720)

    duration
  end

  def normalized_integer(value, field_name)
    return if value.blank?

    Scheduling::IntegerNumericNormalizer.normalize(value, field_name: field_name)
  end

  def custom_attributes
    {
      Integrations::Medelement::ServicesSyncService::EXTERNAL_CODE_KEY => code.to_s,
      Integrations::Medelement::ServicesSyncService::LAST_SEEN_AT_KEY => now.iso8601,
      'medelement_parent_code' => payload['PARENT_CODE'],
      'medelement_parent_name' => payload['PARENT_NAME'],
      'medelement_nesting_level' => payload['NESTING_LEVEL'],
      'medelement_unit_name' => payload['UNIT_NAME']
    }.compact
  end

  def source_active?
    return true unless payload.key?('active')

    ActiveModel::Type::Boolean.new.cast(payload['active'])
  end

  def source_price
    payload['basePrice'].presence || payload['price'].presence || payload['PRICE'].presence
  end

  def log_skipped(reason)
    Rails.logger.warn(
      "[MEDELEMENT::SERVICES_SYNC] Skipping service for account=#{account.id} " \
      "service_code=#{code.presence || 'missing'} reason=#{reason}"
    )
    nil
  end
end
