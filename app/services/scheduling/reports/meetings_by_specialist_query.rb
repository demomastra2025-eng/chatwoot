class Scheduling::Reports::MeetingsBySpecialistQuery # rubocop:disable Metrics/ClassLength
  DEFAULT_PER_PAGE = 25
  MAX_PER_PAGE = 100
  MAX_PAGE = 10_000
  MAX_WINDOW_SECONDS = 366.days.to_i
  LOCAL_DATETIME_PATTERN = /\A(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(\.\d{1,6})?\z/
  QUERY_KIND = 'scheduling_meetings_by_specialist'.freeze
  SOURCE = 'scheduling_appointments'.freeze
  FILTER_KEYS = %i[resource_id team_id service_id].freeze
  STATUSES = Scheduling::Constants::APPOINTMENT_STATUSES.freeze

  attr_reader :account, :from_time, :generated_at, :params, :timezone, :to_time

  def initialize(account:, appointments_scope:, params: {}, generated_at: Time.current)
    @account = account
    @appointments_scope = appointments_scope
    @params = params.to_h.symbolize_keys
    @generated_at = generated_at
    @timezone = account.workspace_working_hours_timezone
    reject_historical_query!
    normalize_window!
    normalize_filters!
  end

  def aggregate_rows
    @aggregate_rows ||= ActiveRecord::Base.connection.exec_query(aggregate_sql).map { |row| aggregate_payload(row) }
  end

  def drill_down_rows = details_result.fetch(:rows)

  def meta
    report_meta.merge(total_count: total_count)
  end

  def pagination_meta
    report_meta.merge(page: page, per_page: per_page, total_count: details_result.fetch(:total_count))
  end

  def relation
    @relation ||= begin
      scope = appointments_scope.where(account_id: account.id)
      scope = scope.where('scheduling_appointments.starts_at >= ?', from_time)
                   .where('scheduling_appointments.starts_at < ?', to_time)
      filters.each { |key, value| scope = scope.where(key => value) }
      scope = scope.where(status: statuses) if statuses.present?
      scope
    end
  end

  private

  attr_reader :appointments_scope, :filters, :statuses

  def normalize_window!
    zone = ActiveSupport::TimeZone[timezone]
    @from_time = parse_local_time!(zone, :from_local)
    @to_time = parse_local_time!(zone, :to_local)
    raise_validation!('to_local must be after from_local') unless to_time > from_time
    raise_validation!('window must not exceed 366 days') if to_time - from_time > MAX_WINDOW_SECONDS
  end

  def reject_historical_query!
    raise_validation!('as_of is not supported for current projections') if params[:as_of].present?
  end

  def normalize_filters!
    @filters = FILTER_KEYS.index_with { |key| parse_optional_positive_integer!(key) }.compact
    @statuses = normalize_statuses
    validate_filter!(:resource_id, account.scheduling_resources)
    validate_filter!(:team_id, account.teams)
    validate_filter!(:service_id, account.scheduling_services)
  end

  def parse_local_time!(zone, key)
    value = params[key]
    raise_validation!("#{key} is required") if value.blank?
    raise_validation!("#{key} must be a local datetime") unless value.is_a?(String)

    match = LOCAL_DATETIME_PATTERN.match(value)
    raise_validation!("#{key} must be an offset-free ISO local datetime") if match.blank?

    local = strict_local_datetime(match)
    zone.tzinfo.local_to_utc(local).to_time.utc.in_time_zone(zone)
  rescue Date::Error, TZInfo::PeriodNotFound, TZInfo::AmbiguousTime
    raise_validation!("#{key} must be an unambiguous existing local datetime")
  end

  def strict_local_datetime(match)
    year, month, day, hour, minute, second = match.captures.first(6).map(&:to_i)
    fraction = match[7].to_s.to_f
    raise Date::Error unless hour.between?(0, 23) && minute.between?(0, 59) && second.between?(0, 59)

    DateTime.new(year, month, day, hour, minute, second + fraction, 0)
  end

  def normalize_statuses
    raw = params[:status]
    return [] if raw.blank?

    values = Array(raw).flat_map { |value| value.to_s.split(',') }.map(&:strip).reject(&:blank?).uniq.sort
    invalid = values - STATUSES
    raise_validation!("status is invalid: #{invalid.join(',')}") if invalid.any?
    values
  end

  def validate_filter!(key, scope)
    return unless filters[key]
    return if scope.exists?(id: filters[key])

    raise_validation!("#{key} is invalid")
  end

  def aggregate_sql
    status_columns = STATUSES.map do |status|
      quoted = ActiveRecord::Base.connection.quote(status)
      "COUNT(*) FILTER (WHERE appointments.status = #{quoted}) AS #{status}_count"
    end.join(', ')

    <<~SQL.squish
      WITH matching_appointments AS MATERIALIZED (#{report_relation.to_sql})
      SELECT appointments.appointment_resource_id,
        resources.id AS resource_catalog_id, resources.name AS resource_name,
        COUNT(*) AS total_count, #{status_columns},
        COUNT(*) FILTER (WHERE appointments.ends_at < appointments.starts_at) AS invalid_duration_count,
        COUNT(*) FILTER (WHERE appointments.ends_at >= appointments.starts_at) AS valid_duration_count,
        COALESCE(SUM(FLOOR(EXTRACT(EPOCH FROM (appointments.ends_at - appointments.starts_at))))
          FILTER (WHERE appointments.ends_at >= appointments.starts_at), 0)::bigint AS scheduled_duration_seconds
      FROM matching_appointments appointments
      LEFT JOIN scheduling_resources resources
        ON resources.id = appointments.appointment_resource_id AND resources.account_id = #{quoted_account_id}
      GROUP BY appointments.appointment_resource_id, resources.id, resources.name
      ORDER BY appointments.appointment_resource_id ASC
    SQL
  end

  def details_sql
    <<~SQL.squish
      WITH matching_appointments AS MATERIALIZED (#{report_relation.to_sql})
      SELECT page.*, totals.report_total_count
      FROM (SELECT COUNT(*) AS report_total_count FROM matching_appointments) totals
      LEFT JOIN LATERAL (
        SELECT appointments.*,
          resources.id AS resource_catalog_id, resources.name AS resource_name,
          teams.id AS team_catalog_id, teams.name AS team_name,
          services.id AS service_catalog_id, services.name AS service_name
        FROM matching_appointments appointments
        LEFT JOIN scheduling_resources resources
          ON resources.id = appointments.appointment_resource_id AND resources.account_id = #{quoted_account_id}
        LEFT JOIN teams ON teams.id = appointments.appointment_team_id AND teams.account_id = #{quoted_account_id}
        LEFT JOIN scheduling_services services
          ON services.id = appointments.appointment_service_id AND services.account_id = #{quoted_account_id}
        ORDER BY appointments.starts_at ASC, appointments.appointment_id ASC
        LIMIT #{per_page} OFFSET #{page_offset}
      ) page ON TRUE
    SQL
  end

  def report_relation
    relation.reselect(
      'scheduling_appointments.id AS appointment_id',
      'scheduling_appointments.resource_id AS appointment_resource_id',
      'scheduling_appointments.team_id AS appointment_team_id',
      'scheduling_appointments.service_id AS appointment_service_id',
      'scheduling_appointments.starts_at',
      'scheduling_appointments.ends_at',
      'scheduling_appointments.status',
      'scheduling_appointments.service_name_snapshot',
      'scheduling_appointments.service_type_snapshot',
      'scheduling_appointments.service_duration_min_snapshot'
    ).reorder(nil)
  end

  def details_result
    @details_result ||= begin
      result = ActiveRecord::Base.connection.exec_query(details_sql).to_a
      {
        rows: result.filter_map { |row| detail_payload(row) if row['appointment_id'] },
        total_count: result.first.fetch('report_total_count').to_i
      }
    end
  end

  def aggregate_payload(row)
    {
      specialist: catalog_projection(row, :resource, required: true),
      total_count: row['total_count'].to_i,
      status_counts: status_counts(row),
      scheduled_duration: {
        seconds: row['scheduled_duration_seconds'].to_i,
        valid_count: row['valid_duration_count'].to_i,
        invalid_count: row['invalid_duration_count'].to_i
      }
    }
  end

  def detail_payload(row)
    {
      appointment_id: row['appointment_id'],
      specialist: catalog_projection(row, :resource, required: true),
      team: catalog_projection(row, :team),
      service: service_projection(row),
      starts_at: iso8601(row['starts_at']),
      starts_at_local: iso8601(row['starts_at']&.in_time_zone(timezone)),
      ends_at: iso8601(row['ends_at']),
      ends_at_local: iso8601(row['ends_at']&.in_time_zone(timezone)),
      status: row['status'],
      scheduled_duration: detail_duration(row)
    }
  end

  def status_counts(row)
    counts = STATUSES.index_with { |status| row["#{status}_count"].to_i }
    counts.merge('unknown' => row['total_count'].to_i - counts.values.sum)
  end

  def detail_duration(row)
    valid = row['ends_at'].present? && row['starts_at'].present? && row['ends_at'] >= row['starts_at']
    { state: valid ? 'exact' : 'invalid_interval', seconds: valid ? (row['ends_at'] - row['starts_at']).floor : nil }
  end

  def catalog_projection(row, prefix, required: false)
    raw_id = row["appointment_#{prefix}_id"]
    catalog_id = row["#{prefix}_catalog_id"]
    state = if catalog_id.present?
              'current_catalog_projection'
            elsif raw_id.blank? && !required
              'not_configured'
            else
              'unknown'
            end
    { id: raw_id, name: catalog_id.present? ? row["#{prefix}_name"] : nil, catalog_state: state }
  end

  def service_projection(row)
    catalog_projection(row, :service).merge(
      snapshot: {
        name: row['service_name_snapshot'],
        type: row['service_type_snapshot'],
        duration_min: row['service_duration_min_snapshot']
      }
    )
  end

  def report_meta
    projection_meta.merge(
      window_meta,
      definition_meta,
      query_fingerprint: query_fingerprint
    )
  end

  def projection_meta
    {
      metric_kind: 'current_projection',
      reliability: 'exact_current_snapshot',
      generated_at: generated_at.utc.iso8601(6),
      generated_at_local: generated_at.in_time_zone(timezone).iso8601(6),
      timezone: timezone,
      definition_version: 1,
      source_version: 1,
      source: SOURCE
    }
  end

  def window_meta
    {
      from: from_time.utc.iso8601(6),
      to: to_time.utc.iso8601(6),
      from_local: from_time.in_time_zone(timezone).iso8601(6),
      to_local: to_time.in_time_zone(timezone).iso8601(6)
    }
  end

  def definition_meta
    {
      metric_definition: 'current_kept_appointments_grouped_by_scheduling_resource_identity',
      cohort_definition: 'appointment_view_intersect_view_reports_with_start_in_workspace_local_half_open_window',
      duration_definition: 'per_appointment_floor_seconds_of_ends_at_minus_starts_at_for_non_negative_intervals',
      catalog_definition: 'resource_team_and_service_names_are_current_catalog_projections; service_snapshot_is_persisted',
      temporal_definition: 'current_projection_at_generated_at_not_historical_attribution; later_reschedule_status_or_resource_edits_change_results',
      reliability_boundary: 'historical_as_of_attribution_unknown_without_immutable_appointment_facts'
    }
  end

  def total_count
    return @aggregate_rows.sum { |row| row[:total_count] } if defined?(@aggregate_rows)

    relation.count
  end

  def page
    @page ||= parse_positive_integer!(:page, default: 1, max: MAX_PAGE)
  end

  def per_page
    @per_page ||= parse_positive_integer!(:per_page, default: DEFAULT_PER_PAGE, max: MAX_PER_PAGE)
  end

  def page_offset = (page - 1) * per_page

  def parse_optional_positive_integer!(key)
    return if params[key].blank?

    parse_positive_integer!(key, default: nil)
  end

  def parse_positive_integer!(key, default:, max: nil)
    value = params[key].presence || default
    raise_validation!("#{key} must be a positive integer") unless value.to_s.match?(/\A[1-9]\d*\z/)

    parsed = value.to_i
    raise_validation!("#{key} must not exceed #{max}") if max && parsed > max
    parsed
  end

  def query_fingerprint
    @query_fingerprint ||= Digest::SHA256.hexdigest(
      [
        QUERY_KIND, account.id, appointments_scope.to_sql,
        from_time.utc.iso8601(6), to_time.utc.iso8601(6), filters.sort, statuses
      ].to_json
    )
  end

  def quoted_account_id = ActiveRecord::Base.connection.quote(account.id)

  def iso8601(value) = value&.iso8601(6)

  def raise_validation!(message)
    raise Scheduling::Error.new(code: 'INVALID_REPORT_QUERY', message: message, status: :unprocessable_content)
  end
end
