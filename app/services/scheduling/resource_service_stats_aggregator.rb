# Builds the specialist-service pairs (Scheduling::ResourceServiceStat) of one account from the visit history.
#
# MedElement gives no specialist-to-service relation through its API, but an imported reception carries the codes of the services
# performed once the visit is over (custom_attributes.medelement_provider_nomenclature_codes), and a service is found by its
# medelement_nomenclature_code. Counting those codes per specialist gives the relation, and the length of those visits gives the
# real duration of the service at that specialist.
#
# The history is the visits of the last WINDOW_DAYS days that were not cancelled and did not end as a no-show. A pair counts when it
# has at least MIN_RECEPTIONS visits and at least MIN_SHARE_PERCENT percent of all the visits that carried the service. Payment
# lines (a prepayment, a deposit) and laboratory tests are not services of a specialist and are left out.
#
# A row is created only for a pair that counts. A later run never deletes a row and never changes a status set by staff (confirmed,
# disabled): a row of status auto that no longer counts becomes stale, and a stale row that counts again becomes auto.
class Scheduling::ResourceServiceStatsAggregator
  WINDOW_DAYS = 180
  MIN_RECEPTIONS = 3
  MIN_SHARE_PERCENT = 5
  EXCLUDED_APPOINTMENT_STATUSES = %w[cancelled no_show].freeze
  # A payment line: «Предоплата 5000», «предоплата УЗИ», «Оплата ...», «Депозит».
  PAYMENT_NAME_PATTERN = /предоплат|оплат|депозит/i
  # A laboratory category: «ЛИС КДЛ ...» (the lab system and the lab itself) or any category named after a laboratory.
  LAB_CATEGORY_PATTERN = /(?<![[:alpha:]])(?:ЛИС|КДЛ)(?![[:alpha:]])|лаборатор/i
  CODES_KEY = Integrations::Medelement::AppointmentServiceBinding::PROVIDER_CODES_KEY
  SERVICE_CODE_KEY = 'medelement_nomenclature_code'.freeze
  UNIQUE_INDEX = 'idx_scheduling_resource_service_stats_on_resource_service'.freeze
  MIN_DURATION = Scheduling::Constants::MIN_DURATION_MINUTES
  MAX_DURATION = Scheduling::Constants::MAX_DURATION_MINUTES

  Result = Data.define(:account_id, :history_pairs, :counted_pairs, :created, :updated, :staled, :unchanged, :dry_run)
  Pair = Struct.new(:resource_id, :service_id, :receptions_count, :median_duration_min, :last_seen_at)

  def self.noise_service?(service)
    service.name.to_s.match?(PAYMENT_NAME_PATTERN) || [service.category, service.direction].any? { |text| text.to_s.match?(LAB_CATEGORY_PATTERN) }
  end

  def initialize(account:, now: Time.current, window_days: WINDOW_DAYS)
    @account = account
    @now = now
    @window_days = window_days
  end

  def perform(dry_run: false)
    pairs = history_pairs
    counted = pairs.select { |pair| counts?(pair) }
    rows, summary = rows_to_write(pairs, counted)
    write(rows) unless dry_run || rows.empty?

    Result.new(account_id: @account.id, history_pairs: pairs.size, counted_pairs: counted.size, dry_run: dry_run, **summary)
  end

  private

  # A pair counts with enough visits, and enough of the visits of its service (the service is mostly done by the others otherwise).
  def counts?(pair)
    pair.receptions_count >= MIN_RECEPTIONS &&
      pair.receptions_count * 100 >= MIN_SHARE_PERCENT * service_totals.fetch(pair.service_id)
  end

  # The pairs of the history: a specialist and a service of the catalog (the codes of no service, payment lines and laboratory tests
  # are dropped).
  def history_pairs
    @history_pairs ||= history_rows.filter_map do |resource_id, code, count, median, last_seen_at|
      service = services_by_code[code]
      next if service.nil? || self.class.noise_service?(service)

      Pair.new(resource_id, service.id, count, median.round.clamp(MIN_DURATION, MAX_DURATION), last_seen_at)
    end
  end

  # The visits that carried each service, over all specialists.
  def service_totals
    @service_totals ||= history_pairs.group_by(&:service_id).transform_values { |pairs| pairs.sum(&:receptions_count) }
  end

  # [resource_id, code, visits, median length, last visit] of each specialist and service code. A code is counted once per visit.
  def history_rows
    @history_rows ||= begin
      binds = { account_id: @account.id, key: CODES_KEY, excluded: EXCLUDED_APPOINTMENT_STATUSES,
                since: @now - @window_days.days, until: @now }
      result = Scheduling::Appointment.connection.select_all(Scheduling::Appointment.sanitize_sql_array([history_sql, binds]))
      result.cast_values.map { |resource_id, code, count, median, last_seen_at| [resource_id, code, count, median.to_f, last_seen_at] }
    end
  end

  def history_sql
    <<~SQL.squish
      SELECT a.resource_id, code.value AS code, COUNT(*) AS receptions_count,
             percentile_cont(0.5) WITHIN GROUP (ORDER BY a.duration_min) AS median_duration_min, MAX(a.starts_at) AS last_seen_at
      FROM scheduling_appointments a
      CROSS JOIN LATERAL (
        SELECT DISTINCT btrim(item.value) AS value
        FROM jsonb_array_elements_text(
          CASE WHEN jsonb_typeof(a.custom_attributes -> :key) = 'array' THEN a.custom_attributes -> :key ELSE '[]'::jsonb END
        ) AS item(value)
        WHERE btrim(item.value) <> ''
      ) code
      WHERE a.account_id = :account_id AND a.status NOT IN (:excluded) AND a.starts_at >= :since AND a.starts_at <= :until
      GROUP BY a.resource_id, code.value
    SQL
  end

  def services_by_code
    @services_by_code ||= begin
      codes = history_rows.pluck(1).uniq
      services = @account.scheduling_services.where("custom_attributes ->> '#{SERVICE_CODE_KEY}' IN (?)", codes.presence || [''])
      services.index_by { |service| service.custom_attributes[SERVICE_CODE_KEY].to_s }
    end
  end

  def existing_rows
    @existing_rows ||= Scheduling::ResourceServiceStat.where(account_id: @account.id).index_by { |row| [row.resource_id, row.service_id] }
  end

  # The rows to write and the counts of what the write does. A pair that counts is written as auto; a row that no longer counts keeps
  # what the history says now (zero visits when the pair is gone) and becomes stale unless staff set its status.
  def rows_to_write(pairs, counted)
    history = pairs.index_by { |pair| [pair.resource_id, pair.service_id] }
    counted_keys = counted.to_set { |pair| [pair.resource_id, pair.service_id] }
    summary = { created: 0, updated: 0, staled: 0, unchanged: 0 }
    rows = []

    (counted_keys | existing_rows.keys).each do |key|
      row = row_for(key, history[key], counted_keys.include?(key))
      outcome = outcome_of(row, existing_rows[key])
      summary[outcome] += 1
      rows << row unless outcome == :unchanged
    end
    [rows, summary]
  end

  def row_for(key, pair, counted)
    existing = existing_rows[key]
    {
      account_id: @account.id, resource_id: key[0], service_id: key[1], source: Scheduling::ResourceServiceStat::SOURCE_HISTORY,
      receptions_count: pair&.receptions_count || 0,
      median_duration_min: pair&.median_duration_min || existing&.median_duration_min,
      last_seen_at: pair&.last_seen_at || existing&.last_seen_at,
      status: next_status(existing, counted)
    }
  end

  def next_status(existing, counted)
    return existing.status if existing&.manual?

    counted ? Scheduling::ResourceServiceStat::STATUS_AUTO : Scheduling::ResourceServiceStat::STATUS_STALE
  end

  def outcome_of(row, existing)
    return :created if existing.nil?
    return :unchanged if unchanged?(row, existing)

    row[:status] == Scheduling::ResourceServiceStat::STATUS_STALE && existing.status != row[:status] ? :staled : :updated
  end

  def unchanged?(row, existing)
    row.slice(:receptions_count, :median_duration_min, :status).all? { |attribute, value| existing[attribute] == value } &&
      existing.last_seen_at&.to_i == row[:last_seen_at]&.to_i
  end

  # One statement. A status set by staff while this run was reading is kept by the database itself.
  def write(rows)
    manual = Scheduling::ResourceServiceStat::MANUAL_STATUSES.map { |status| Scheduling::ResourceServiceStat.connection.quote(status) }.join(', ')
    table = Scheduling::ResourceServiceStat.quoted_table_name
    on_duplicate = Arel.sql(<<~SQL.squish)
      receptions_count = excluded.receptions_count, median_duration_min = excluded.median_duration_min,
      last_seen_at = excluded.last_seen_at, updated_at = excluded.updated_at,
      status = CASE WHEN #{table}.status IN (#{manual}) THEN #{table}.status ELSE excluded.status END
    SQL
    rows.each_slice(500) do |slice|
      Scheduling::ResourceServiceStat.upsert_all(slice, unique_by: UNIQUE_INDEX, on_duplicate: on_duplicate) # rubocop:disable Rails/SkipsModelValidations
    end
  end
end
