class Integrations::Medelement::ServicesSyncService
  EXTERNAL_CODE_KEY = 'medelement_nomenclature_code'.freeze
  LAST_SEEN_AT_KEY = 'medelement_last_seen_at'.freeze
  MISSING_GRACE_PERIOD = 7.days

  class IncompleteSnapshotError < StandardError; end

  def initialize(account:, client:, **options)
    @account = account
    @client = client
    @service_payloads = options[:service_payloads]
    @specialist_service_payloads = options[:specialist_service_payloads]
    @now = options.fetch(:now, Time.current)
    @conflict_tracker = options[:conflict_tracker]
  end

  def perform
    result = nil
    rows = service_rows
    provider_codes = provider_service_codes(rows)
    raise IncompleteSnapshotError, 'Medelement services snapshot has no services' if provider_codes.empty?

    Scheduling::Service.transaction do
      imported_services, skipped_count = import_services(rows)
      linked_count = sync_specialist_services(imported_services)
      deactivate_stale_services!(provider_codes) if provider_codes.present? && skipped_count.zero?
      record_not_returned_services!(provider_codes)
      result = sync_result(imported_services, linked_count, skipped_count, provider_codes)
    end

    result
  end

  private

  attr_reader :account, :client, :conflict_tracker, :now, :service_payloads, :specialist_service_payloads

  def service_rows
    return Array(service_payloads) unless service_payloads.nil?

    Integrations::Medelement::NomenclaturesSnapshotService.new(client: client).perform
  end

  def import_services(rows)
    services = {}
    skipped_count = 0

    rows.each do |raw_payload|
      payload = raw_payload.to_h.with_indifferent_access
      next if group_payload?(payload)

      service = Integrations::Medelement::ServiceUpsertService.new(
        account: account,
        payload: payload,
        now: now,
        conflict_tracker: conflict_tracker
      ).perform
      skipped_count += 1 unless service
      services[service.custom_attributes[EXTERNAL_CODE_KEY]] = service if service
    end

    [services, skipped_count]
  end

  def group_payload?(payload)
    payload.key?('IS_GROUP') && payload['IS_GROUP'].to_i == 1
  end

  def sync_specialist_services(services_by_code)
    Array(specialist_service_payloads).count do |payload|
      Integrations::Medelement::SpecialistServiceUpsertService.new(
        account: account,
        payload: payload,
        services_by_code: services_by_code,
        conflict_tracker: conflict_tracker
      ).perform
    end
  end

  def deactivate_stale_services!(seen_codes)
    medelement_services.find_each do |service|
      next if seen_codes.include?(service.custom_attributes[EXTERNAL_CODE_KEY])
      next unless stale?(service.custom_attributes[LAST_SEEN_AT_KEY])

      service.update!(active: false)
      service.prices.find_each { |service_price| service_price.update!(active: false) }
    end
  end

  def medelement_services
    account.scheduling_services.where("NULLIF(custom_attributes ->> '#{EXTERNAL_CODE_KEY}', '') IS NOT NULL")
  end

  def local_services
    account.scheduling_services.active.where("NULLIF(custom_attributes ->> '#{EXTERNAL_CODE_KEY}', '') IS NULL")
  end

  def provider_service_codes(rows)
    Array(rows).filter_map do |raw_payload|
      payload = raw_payload.to_h.with_indifferent_access
      (payload['serviceCode'].presence || payload['NOMENCLATURE_CODE'].presence).to_s.presence unless group_payload?(payload)
    end.to_set
  end

  def stale?(last_seen_at)
    return false if last_seen_at.blank?

    Time.iso8601(last_seen_at) < now - MISSING_GRACE_PERIOD
  rescue ArgumentError
    false
  end

  def sync_result(imported_services, linked_count, skipped_count, provider_codes)
    {
      provider_count: provider_codes.size,
      imported_count: imported_services.size,
      linked_count: linked_count,
      skipped_count: skipped_count,
      not_returned_count: not_returned_count(provider_codes),
      local_unlinked_count: local_services.count
    }
  end

  def not_returned_count(provider_codes)
    return medelement_services.count if provider_codes.empty?

    medelement_services.where.not("custom_attributes ->> '#{EXTERNAL_CODE_KEY}' IN (?)", provider_codes.to_a).count
  end

  def record_not_returned_services!(provider_codes)
    not_returned = medelement_services.active
    not_returned = not_returned.where.not("custom_attributes ->> '#{EXTERNAL_CODE_KEY}' IN (?)", provider_codes.to_a)
    not_returned.find_each do |service|
      service_code = service.custom_attributes[EXTERNAL_CODE_KEY]
      conflict_tracker&.record!(
        phase: 'services',
        entity_type: 'service',
        conflict_type: 'service_not_returned',
        entity_key: service_code,
        severity: 'warning',
        details: {
          reason: 'Service linked in One Link was not returned by the Medelement nomenclature API',
          service_id: service.id,
          service_code: service_code,
          service_name: service.name,
          last_seen_at: service.custom_attributes[LAST_SEEN_AT_KEY]
        }.compact
      )
    end
  end
end
