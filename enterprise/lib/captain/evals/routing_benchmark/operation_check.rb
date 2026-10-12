# frozen_string_literal: true

# Compares the appointment operations that a fixture turn expects with the rows the turn really created, moved or
# cancelled (see BookingChanges). An expectation is
#
#   {model: appointment, kind: create|update|cancel, params: {status: scheduled},   # database columns, exact
#    resource: doctor_a, service: consult, starts_at: '2026-10-15T12:00:00+05:00',   # symbolic, optional
#    patient: m_marat | patient_name: Арсен, count: 1,                               # who, and how many rows
#    previous_starts_at: '2026-10-13T15:00:00+05:00', previous_resource: doctor_b}   # the row an update must start from
#
# `params` alone (the old form) accepts any row of the kind with those column values. The symbolic keys compare the
# doctor, the service, the start, the patient and the old appointment with the row, so a booking with the wrong
# doctor, time, service or patient is an `operation_mismatch:<field>` and not a pass. `count` is the exact number of
# matching rows (default 1): a second row for one request is `operation_mismatch:count`.
#
# Reasons: missing_operation:appointment (no row of the kind with those params) and operation_mismatch:<field>.
class Captain::Evals::RoutingBenchmark::OperationCheck
  KIND_VERBS = { 'create' => 'created', 'update' => 'updated', 'cancel' => 'cancelled' }.freeze
  Result = Struct.new(:failures, :explained_ids, keyword_init: true)

  def initialize(changes:, directory: nil)
    @changes = changes
    @directory = directory
  end

  def call(operations)
    failures = []
    explained = Set.new
    Array(operations).each do |operation|
      next unless operation['model'] == 'appointment'

      explained.merge(check(operation, failures))
    end
    Result.new(failures: failures, explained_ids: explained)
  end

  private

  # Appends the failures of one expectation; returns the ids of the rows it accounts for.
  def check(operation, failures)
    kind = operation.fetch('kind', 'create')
    count = Integer(operation.fetch('count', 1))
    rows = with_params(@changes.for_kind(kind), operation)
    return [] if rows.empty? && count.zero?

    if rows.empty?
      failures << { id: 'missing_operation:appointment', detail: "no appointment was #{KIND_VERBS.fetch(kind)}" }
      return []
    end
    matching = rows.select { |row| mismatches(row, operation).empty? }
    return matching.map(&:id) if matching.size == count

    # Every row of the kind is reported through this expectation. When it is met, a row of the kind that does not match
    # is not accounted for and falls to unexpected_mutation.
    failures.concat(mismatch_failures(rows, matching, operation, count, kind))
    rows.map(&:id)
  end

  def mismatch_failures(rows, matching, operation, count, kind)
    if matching.any? || count.zero?
      detail = "#{matching.size} matching of #{rows.size} #{KIND_VERBS.fetch(kind)} appointments, expected #{count}"
      return [{ id: 'operation_mismatch:count', detail: detail }]
    end

    closest = rows.min_by { |row| mismatches(row, operation).size }
    mismatches(closest, operation).map do |field|
      { id: "operation_mismatch:#{field}", detail: "appointment #{closest.id}: #{field} #{actual(closest, field)}, " \
                                                   "expected #{expected(operation, field)}" }
    end
  end

  def with_params(rows, operation)
    params = operation['params'] || {}
    return rows if params.empty? || rows.empty?

    ids = Scheduling::Appointment.where(id: rows.map(&:id)).where(params).pluck(:id)
    rows.select { |row| ids.include?(row.id) }
  end

  def mismatches(row, operation)
    record = row.record
    fields = []
    fields << 'resource' if operation['resource'] && record.resource_id != directory.resource_id(operation['resource'])
    fields << 'service' if operation['service'] && record.service_id != directory.service_id(operation['service'])
    fields << 'starts_at' if operation['starts_at'] && record.starts_at != Time.iso8601(operation['starts_at'])
    fields << 'patient' if patient_mismatch?(row, operation)
    fields.concat(previous_mismatches(row, operation))
    fields
  end

  def patient_mismatch?(row, operation)
    return true if operation['patient'] && row.patient_id != directory.contact_id(operation['patient'])

    operation['patient_name'] && !names_patient?(row.record, operation['patient_name'])
  end

  # The old appointment of an update; unknown (no pre-turn state) is not a mismatch.
  def previous_mismatches(row, operation)
    previous = row.previous
    return [] if previous.nil?

    fields = []
    fields << 'previous_starts_at' if operation['previous_starts_at'] && previous['starts_at'] != Time.iso8601(operation['previous_starts_at'])
    if operation['previous_resource'] && previous['resource_id'] != directory.resource_id(operation['previous_resource'])
      fields << 'previous_resource'
    end
    fields
  end

  # A name part of the expected patient, compared by stem to survive Russian and Kazakh case endings, occurs in one of
  # the names of the appointment.
  def names_patient?(record, expected_name)
    words = [record.client_first_name, record.client_last_name, record.client_name, record.patient_contact&.name]
            .flat_map { |name| name.to_s.downcase.tr('ё', 'е').scan(/\p{L}+/) }
    expected_name.to_s.downcase.tr('ё', 'е').scan(/\p{L}{3,}/).any? do |token|
      stem = token.first([token.length - 2, 3].max)
      words.any? { |word| word.start_with?(stem) }
    end
  end

  def actual(row, field)
    record = row.record
    case field
    when 'resource' then directory.resource_key(record.resource_id) || record.resource&.name
    when 'service' then directory.service_key(record.service_id) || record.service&.name
    when 'starts_at' then record.starts_at.iso8601
    when 'patient' then directory.contact_key(row.patient_id) || record.client_name
    else row.previous&.dig(field.delete_prefix('previous_')).to_s
    end
  end

  def expected(operation, field)
    field == 'patient' ? (operation['patient'] || operation['patient_name']) : operation[field]
  end

  def directory
    @directory || raise(ArgumentError, 'An operation expectation names a doctor, service or patient but no directory was given')
  end
end
