class Integrations::Medelement::CatalogImportService
  REQUIRED_SECTIONS = %w[specialists cabinets services specialistServices].freeze

  class InvalidPayloadError < StandardError; end

  def initialize(hook:, payload:, now: Time.current)
    @account_id = hook.account_id
    @hook_id = hook.id
    @payload = payload.is_a?(Hash) ? payload.with_indifferent_access : {}.with_indifferent_access
    @now = now
  end

  def perform
    validate_payload!

    Integrations::Medelement::HookRuntimeLock.with_hook(account_id: account_id, hook_id: hook_id) do |hook|
      @account = hook.account
      @configuration = Integrations::Medelement::Configuration.new(hook: hook)
      result = import_catalog
      validate_result!(result)
      result
    end
  end

  private

  attr_reader :account, :account_id, :configuration, :hook_id, :now, :payload

  def import_catalog
    specialist_result = Integrations::Medelement::SpecialistsSyncService.new(
      account: account,
      client: nil,
      configuration: configuration,
      source: { specialists: payload['specialists'], cabinets: payload['cabinets'] },
      now: now
    ).perform
    service_result = Integrations::Medelement::ServicesSyncService.new(
      account: account,
      client: nil,
      service_payloads: payload['services'],
      specialist_service_payloads: payload['specialistServices'],
      now: now
    ).perform

    { specialists: specialist_result, services: service_result }
  end

  def validate_payload!
    invalid_sections = REQUIRED_SECTIONS.reject { |section| payload[section].is_a?(Array) }
    raise_invalid!("Missing or invalid sections: #{invalid_sections.join(', ')}") if invalid_sections.any?
    raise_invalid!('Specialists and services must not be empty') if payload['specialists'].empty? || payload['services'].empty?

    validate_rows!
    validate_unique_codes!
    validate_references!
  end

  def validate_rows!
    validate_section_rows!('specialists') { |row| valid_specialist_row?(row) }
    validate_section_rows!('services') { |row| row['serviceCode'].present? && row['name'].present? }
    validate_section_rows!('specialistServices') { |row| row['specialistCode'].present? && row['serviceCode'].present? }
  end

  def validate_section_rows!(section)
    invalid_index = payload[section].index { |row| !row.is_a?(Hash) || !yield(row) }
    raise_invalid!("Invalid #{section} row at index #{invalid_index}") if invalid_index
  end

  def valid_specialist_row?(row)
    row['specialistCode'].present? && (row['userName'].present? || row['fullName'].present?)
  end

  def validate_unique_codes!
    raise_invalid!('Specialists contain duplicate specialistCode values') if duplicate_values?(payload['specialists'], 'specialistCode')
    raise_invalid!('Services contain duplicate serviceCode values') if duplicate_values?(payload['services'], 'serviceCode')

    link_keys = payload['specialistServices'].map { |row| [row['specialistCode'].to_s, row['serviceCode'].to_s] }
    raise_invalid!('specialistServices contains duplicate links') if link_keys.uniq.size != link_keys.size
  end

  def validate_references!
    specialist_codes = payload['specialists'].pluck('specialistCode').to_set(&:to_s)
    service_codes = payload['services'].pluck('serviceCode').to_set(&:to_s)
    invalid_reference = payload['specialistServices'].any? do |row|
      specialist_codes.exclude?(row['specialistCode'].to_s) || service_codes.exclude?(row['serviceCode'].to_s)
    end
    raise_invalid!('specialistServices references an unknown specialist or service') if invalid_reference
  end

  def validate_result!(result)
    exact_counts = result.dig(:specialists, :imported_count) == payload['specialists'].size &&
                   result.dig(:services, :imported_count) == payload['services'].size &&
                   result.dig(:services, :linked_count) == payload['specialistServices'].size &&
                   result.dig(:services, :skipped_count).zero?
    raise_invalid!('Not all catalog rows could be imported') unless exact_counts
  end

  def duplicate_values?(rows, key)
    values = rows.map { |row| row[key].to_s }
    values.uniq.size != values.size
  end

  def raise_invalid!(message)
    raise InvalidPayloadError, message
  end
end
