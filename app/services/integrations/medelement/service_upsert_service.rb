class Integrations::Medelement::ServiceUpsertService
  MAX_NAME_LENGTH = 255

  def initialize(account:, payload:, now:, conflict_tracker: nil)
    @account = account
    @payload = payload.to_h.with_indifferent_access
    @now = now
    @conflict_tracker = conflict_tracker
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

  attr_reader :account, :conflict_tracker, :now, :payload

  def assign_required_attributes(service)
    service.assign_attributes(
      account: service.account || account,
      name: name,
      active: source_active?,
      custom_attributes: merged_custom_attributes(service)
    )
  end

  def merged_custom_attributes(service)
    service.custom_attributes.merge(custom_attributes).tap do |attributes|
      attributes.delete('medelement_full_name') unless raw_name.to_s.length > MAX_NAME_LENGTH
    end
  end

  def assign_optional_attributes(service)
    assign_present_attribute(service, :base_price, normalized_price)
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
    @name ||= raw_name&.truncate(MAX_NAME_LENGTH, omission: '…')
  end

  def raw_name
    @raw_name ||= payload['name'].presence || payload['NOMENCLATURE_NAME'].presence
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

  def normalized_price
    return if source_price.blank?

    value = BigDecimal(source_price.to_s, exception: false)
    raise ArgumentError, 'price is not numeric' if value.nil? || value.negative?

    value.round(0, half: :up).to_i
  end

  def custom_attributes
    attributes = {
      Integrations::Medelement::ServicesSyncService::EXTERNAL_CODE_KEY => code.to_s,
      Integrations::Medelement::ServicesSyncService::LAST_SEEN_AT_KEY => now.iso8601,
      'medelement_parent_code' => payload['PARENT_CODE'],
      'medelement_parent_name' => payload['PARENT_NAME'],
      'medelement_nesting_level' => payload['NESTING_LEVEL'],
      'medelement_unit_name' => payload['UNIT_NAME'],
      'medelement_price_raw' => normalized_price_raw
    }
    attributes['medelement_full_name'] = raw_name if raw_name.to_s.length > MAX_NAME_LENGTH
    attributes.compact
  end

  def source_active?
    key = %w[active ACTIVE].find { |candidate| payload.key?(candidate) }
    return true unless key

    ActiveModel::Type::Boolean.new.cast(payload[key])
  end

  def source_price
    payload['basePrice'].presence || payload['price'].presence || payload['PRICE'].presence
  end

  def normalized_price_raw
    value = BigDecimal(source_price.to_s, exception: false)
    value&.to_s('F')
  end

  def log_skipped(reason)
    entity_key = code.presence || "missing:#{raw_name}"
    conflict_tracker&.record!(
      phase: 'services',
      entity_type: 'service',
      conflict_type: 'invalid_service',
      entity_key: entity_key,
      severity: 'error',
      details: { reason: reason }
    )
    Rails.logger.warn(
      "[MEDELEMENT::SERVICES_SYNC] Skipping service for account=#{account.id} " \
      "entity_digest=#{Integrations::Medelement::ErrorSanitizer.digest(entity_key)} reason=#{reason}"
    )
    nil
  end
end
