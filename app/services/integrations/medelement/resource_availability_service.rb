class Integrations::Medelement::ResourceAvailabilityService
  PAGE_SIZE = 50
  MAX_PAGES = 20
  PROVIDER_TIME_FORMAT = '%d.%m.%Y %H:%M:%S'.freeze

  Result = Data.define(:status, :checked_at, :slots, :reason)

  def initialize(resource:, from:, to:, slots:, **options)
    @resource = resource
    @from = from
    @to = to
    @slots = slots
    @configuration = configuration
    @client = options[:client]
    @cabinet_code = options[:cabinet_code].to_s.presence
    @exclude_reception_code = options[:exclude_reception_code].to_s.presence
  end

  def perform
    checked_at = Time.current
    return unavailable(checked_at, 'provider_configuration_missing') if @configuration.blank?
    return unavailable(checked_at, 'provider_cabinet_missing') if cabinets.blank?

    provider_windows = provider_working_windows
    receptions = cabinets.to_h { |cabinet| [cabinet.fetch(:code), provider_receptions(cabinet.fetch(:code))] }

    Result.new(
      status: 'fresh',
      checked_at: checked_at,
      slots: provider_slots(provider_windows, receptions, checked_at),
      reason: nil
    )
  rescue Integrations::Medelement::Client::ApiError => e
    log_unavailable(e)
    unavailable(checked_at || Time.current, 'provider_unavailable')
  rescue StandardError => e
    log_unavailable(e)
    unavailable(checked_at || Time.current, 'provider_response_invalid')
  end

  private

  def configuration
    hook = resource.account.hooks.enabled.find_by(app_id: 'medelement')
    return if hook.blank? || !hook.feature_allowed?

    Integrations::Medelement::Configuration.new(hook: hook)
  end

  def specialist_code
    resource.custom_attributes.to_h['medelement_specialist_code'].to_s.presence
  end

  def cabinets
    @cabinets ||= begin
      values = Array(resource.custom_attributes.to_h['medelement_cabinets']).filter_map do |payload|
        attributes = payload.to_h.with_indifferent_access
        code = Integrations::Medelement::CabinetAttributes.code(payload)
        next if code.blank?

        { code: code, name: attributes['cabinetName'].to_s.presence }
      end
      values = restrict_cabinets(values)
      values.uniq { |cabinet| cabinet.fetch(:code) }.sort_by { |cabinet| cabinet.fetch(:code) }
    end
  end

  def restrict_cabinets(values)
    return values if @cabinet_code.blank?

    values.select { |cabinet| cabinet.fetch(:code) == @cabinet_code }
  end

  def provider_working_windows
    payload = client.timetable(
      specialist_code: specialist_code,
      starts_on: @from.in_time_zone(resource.timezone).to_date,
      ends_on: @to.in_time_zone(resource.timezone).to_date
    )

    rows = timetable_rows(payload)
    rows.filter_map do |row|
      attributes = row.to_h.with_indifferent_access
      next unless ActiveModel::Type::Boolean.new.cast(attributes['working'])

      interval(attributes['start'], attributes['end'])
    end.sort_by(&:first)
  end

  def timetable_rows(payload)
    payload.values.flat_map { |day| Array(day.to_h['timetable']) }
  end

  def provider_receptions(cabinet_code)
    rows = []

    MAX_PAGES.times do |page|
      batch = Array(
        client.get_receptions(
          company_cabinet_code: cabinet_code,
          specialist_code: specialist_code,
          begin_datetime: provider_time(@from),
          end_datetime: provider_time(@to),
          skip: page * PAGE_SIZE
        )
      )
      rows.concat(batch)
      return occupied_intervals(rows) if batch.length < PAGE_SIZE
    end

    raise Integrations::Medelement::Client::ApiError, 'Medelement reception pagination limit reached'
  end

  def occupied_intervals(rows)
    rows.filter_map do |row|
      attributes = row.to_h.with_indifferent_access
      removed = Integer(attributes['REMOVED'], exception: false)
      raise ArgumentError, 'Invalid Medelement reception state' unless removed.in?([0, 1])
      next if removed == 1
      next if attributes['RECEPTION_CODE'].to_s == @exclude_reception_code

      interval(attributes['STARTTIME'], attributes['ENDTIME'])
    end
  end

  def provider_slots(provider_windows, receptions, checked_at)
    @slots.filter_map do |slot|
      starts_at = parse_time(slot.fetch(:starts_at))
      ends_at = parse_time(slot.fetch(:ends_at))
      next unless fully_covered?(starts_at, ends_at, provider_windows)

      cabinet = cabinets.find do |candidate|
        receptions.fetch(candidate.fetch(:code)).none? { |occupied| overlaps?(starts_at, ends_at, occupied) }
      end
      next if cabinet.blank?

      slot.merge(
        availability_source: 'medelement',
        provider_checked_at: checked_at.iso8601(6),
        medelement_cabinet_code: cabinet.fetch(:code),
        medelement_cabinet_name: cabinet[:name]
      ).compact
    end
  end

  def fully_covered?(starts_at, ends_at, windows)
    cursor = starts_at
    windows.each do |window_start, window_end|
      next if window_end <= cursor
      break if window_start > cursor

      cursor = [cursor, window_end].max
      return true if cursor >= ends_at
    end
    false
  end

  def overlaps?(starts_at, ends_at, interval)
    starts_at < interval.last && ends_at > interval.first
  end

  def interval(start_value, end_value)
    starts_at = parse_time(start_value)
    ends_at = parse_time(end_value)
    raise ArgumentError, 'Invalid Medelement time interval' if starts_at.blank? || ends_at.blank? || ends_at <= starts_at

    [starts_at, ends_at]
  end

  def parse_time(value)
    return value.in_time_zone(resource.timezone) if value.respond_to?(:in_time_zone)

    ActiveSupport::TimeZone[resource.timezone]&.parse(value.to_s)
  end

  def provider_time(value)
    value.in_time_zone(resource.timezone).strftime(PROVIDER_TIME_FORMAT)
  end

  def client
    @client ||= Integrations::Medelement::Client.new(configuration: @configuration)
  end

  def unavailable(checked_at, reason)
    Result.new(status: 'unavailable', checked_at: checked_at, slots: [], reason: reason)
  end

  def log_unavailable(error)
    Rails.logger.warn(
      "[MEDELEMENT::AVAILABILITY] account=#{resource.account_id} resource=#{resource.id} " \
      "error=#{error.class.name}"
    )
  end

  attr_reader :resource
end
