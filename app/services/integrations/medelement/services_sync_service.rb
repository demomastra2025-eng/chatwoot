class Integrations::Medelement::ServicesSyncService
  EXTERNAL_CODE_KEY = 'medelement_nomenclature_code'.freeze
  LAST_SEEN_AT_KEY = 'medelement_last_seen_at'.freeze
  MISSING_GRACE_PERIOD = 7.days

  class IncompleteSnapshotError < StandardError; end

  def initialize(account:, client:, service_payloads: nil, specialist_service_payloads: nil, now: Time.current)
    @account = account
    @client = client
    @service_payloads = service_payloads
    @specialist_service_payloads = specialist_service_payloads
    @now = now
  end

  def perform
    result = nil
    rows = service_rows

    Scheduling::Service.transaction do
      imported_services, skipped_count = import_services(rows)
      linked_count = sync_specialist_services(imported_services)
      deactivate_stale_services!(imported_services.keys)
      result = sync_result(imported_services, linked_count, skipped_count)
    end

    result
  end

  private

  attr_reader :account, :client, :now, :service_payloads, :specialist_service_payloads

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

      service = Integrations::Medelement::ServiceUpsertService.new(account: account, payload: payload, now: now).perform
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
        services_by_code: services_by_code
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
    account.scheduling_services.where("custom_attributes ->> '#{EXTERNAL_CODE_KEY}' IS NOT NULL")
  end

  def stale?(last_seen_at)
    return false if last_seen_at.blank?

    Time.iso8601(last_seen_at) < now - MISSING_GRACE_PERIOD
  rescue ArgumentError
    false
  end

  def sync_result(imported_services, linked_count, skipped_count)
    {
      imported_count: imported_services.size,
      linked_count: linked_count,
      skipped_count: skipped_count
    }
  end
end
