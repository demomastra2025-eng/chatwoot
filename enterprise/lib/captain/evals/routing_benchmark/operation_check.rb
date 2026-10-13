# frozen_string_literal: true

# Compares the appointment operations that a fixture turn expects with the rows the turn really created, moved or
# cancelled (see BookingChanges). An expectation is
#
#   {model: appointment, kind: create|update|cancel,
#    params: {status: scheduled, starts_at: '2026-10-15T12:00:00+05:00'},           # database columns, exact (starts_at: see below)
#    resource: doctor_a, service: consult,                                          # symbolic, optional
#    patient: m_marat | patient_name: Арсен, count: 1,                               # who, and how many rows
#    previous_starts_at: '2026-10-13T15:00:00+05:00', previous_resource: doctor_b}   # the row an update must start from
#
# `params` alone accepts any row of the kind with those column values; the old form of a cancellation,
# {kind: update, params: {status: cancelled}}, is read as kind cancel (see .kind_of). The start is the one column that is not
# filtered by the database: `params.starts_at` (v2 fixtures) or the symbolic `starts_at` is compared with the row, like the
# doctor, the service, the patient and the old appointment, so a booking with the wrong doctor, time, service or patient is an
# `operation_mismatch:<field>` and not a pass. `count` is the exact number of matching rows (default 1): a second row for one
# request is `operation_mismatch:count`.
#
# A row answers one expectation: the rows that match an expectation exactly are claimed first, and an expectation that no exact row
# meets is compared only with the rows nobody claimed, so the one booking that meets the first of two expectations is not also
# reported as a wrong answer to the second (the second is missing).
#
# `previous_starts_at` names the start the appointment had when the dialogue began (a move the turn before had already made does not
# change it): it is met by the start of the row before this turn and by the first start the dialogue saw of it (`origins`).
#
# Reasons: missing_operation:appointment (no row of the kind with those params) and operation_mismatch:<field>.
class Captain::Evals::RoutingBenchmark::OperationCheck
  KIND_VERBS = { 'create' => 'created', 'update' => 'updated', 'cancel' => 'cancelled' }.freeze
  # failures, the ids of the rows that the expectations account for, and the expectations that found no row of their kind at all
  # (`missing`).
  Result = Struct.new(:failures, :explained_ids, :missing, keyword_init: true)

  class << self
    # The kind an appointment expectation stands for. The first fixtures wrote a cancellation as an update that sets the
    # status to cancelled ({kind: update, params: {status: cancelled}}); BookingChanges files such a row under `cancelled`,
    # not under `updated`, so the old form is read as the cancellation it describes.
    def kind_of(operation)
      kind = operation.fetch('kind', 'create')
      kind == 'update' && operation.dig('params', 'status').to_s == 'cancelled' ? 'cancel' : kind
    end

    # The start an appointment expectation pins: the symbolic `starts_at`, else `params.starts_at`.
    def expected_start(operation)
      operation['starts_at'].presence || operation.dig('params', 'starts_at').presence
    end
  end

  # origins: { appointment id => the first start the dialogue saw of it }
  def initialize(changes:, directory: nil, origins: {})
    @changes = changes
    @directory = directory
    @origins = origins
  end

  def call(operations)
    appointment_operations = Array(operations).select { |operation| operation['model'] == 'appointment' }
    claimed = Set.new
    explained = Set.new
    unmet = appointment_operations.reject { |operation| exact_match?(operation, claimed, explained) }
    failures = []
    missing = []
    unmet.each { |operation| report_unmet(operation, claimed, explained, failures, missing) }
    Result.new(failures: failures, explained_ids: explained, missing: missing)
  end

  # Whether the row is a change of the kind of the expectation that meets it in every pinned field.
  def matches?(row, operation)
    kind = self.class.kind_of(operation)
    @changes.for_kind(kind).any? { |item| item.id == row.id } && with_params([row], operation).any? && mismatches(row, operation).empty?
  end

  private

  # The expectation is met when exactly `count` unclaimed rows of its kind match it in every pinned field; they are claimed.
  def exact_match?(operation, claimed, explained)
    count = Integer(operation.fetch('count', 1))
    matching = unclaimed_rows(operation, claimed).select { |row| mismatches(row, operation).empty? }
    return false unless matching.size == count

    claimed.merge(matching.map(&:id))
    explained.merge(matching.map(&:id))
    true
  end

  # An expectation that no exact row meets: nothing of its kind is left (missing), or the rows left differ from it. Every row of
  # the kind that is left is reported through this expectation; a row it does not account for would fall to unexpected_mutation.
  def report_unmet(operation, claimed, explained, failures, missing)
    kind = self.class.kind_of(operation)
    count = Integer(operation.fetch('count', 1))
    rows = unclaimed_rows(operation, claimed)
    if rows.empty?
      failures << { id: 'missing_operation:appointment', detail: "no appointment was #{KIND_VERBS.fetch(kind)}" }
      missing << operation
      return
    end

    matching = rows.select { |row| mismatches(row, operation).empty? }
    failures.concat(mismatch_failures(rows, matching, operation, count, kind))
    claimed.merge(rows.map(&:id))
    explained.merge(rows.map(&:id))
  end

  def unclaimed_rows(operation, claimed)
    with_params(@changes.for_kind(self.class.kind_of(operation)), operation).reject { |row| claimed.include?(row.id) }
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
    # The start is compared in #mismatches, so a wrong time is an operation_mismatch (critical) and not a missing operation.
    params = (operation['params'] || {}).except('starts_at')
    return rows if params.empty? || rows.empty?

    ids = Scheduling::Appointment.where(id: rows.map(&:id)).where(params).pluck(:id)
    rows.select { |row| ids.include?(row.id) }
  end

  def mismatches(row, operation)
    record = row.record
    fields = []
    fields << 'resource' if operation['resource'] && record.resource_id != directory.resource_id(operation['resource'])
    fields << 'service' if operation['service'] && record.service_id != directory.service_id(operation['service'])
    start = self.class.expected_start(operation)
    fields << 'starts_at' if start && record.starts_at != Time.iso8601(start)
    fields << 'patient' if patient_mismatch?(row, operation)
    fields.concat(previous_mismatches(row, operation))
    fields
  end

  def patient_mismatch?(row, operation)
    return true if operation['patient'] && row.patient_id != directory.contact_id(operation['patient'])

    operation['patient_name'] && !names_patient?(row.record, operation['patient_name'])
  end

  # The old appointment of an update; unknown (no pre-turn state) is not a mismatch. The start it moves from is the one it had before
  # this turn, or the first one the dialogue saw: a correction ("лучше на 11:30") moves the appointment that the turn before had moved
  # already, and the fixture names the appointment by the start it had at the beginning.
  def previous_mismatches(row, operation)
    previous = row.previous
    return [] if previous.nil?

    fields = []
    fields << 'previous_starts_at' if operation['previous_starts_at'] && !moved_from?(row, previous, Time.iso8601(operation['previous_starts_at']))
    if operation['previous_resource'] && previous['resource_id'] != directory.resource_id(operation['previous_resource'])
      fields << 'previous_resource'
    end
    fields
  end

  def moved_from?(row, previous, start)
    [previous['starts_at'], @origins[row.id]].compact.include?(start)
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
    case field
    when 'patient' then operation['patient'] || operation['patient_name']
    when 'starts_at' then self.class.expected_start(operation)
    else operation[field]
    end
  end

  def directory
    @directory || raise(ArgumentError, 'An operation expectation names a doctor, service or patient but no directory was given')
  end
end
