# frozen_string_literal: true

# What one customer turn did to the appointments of the synthetic account, read from the database rows and not from
# the tool calls: which rows were created, which existing rows were updated or cancelled, and which active rows now
# overlap. `before` is the id => updated_at snapshot taken before the turn; `before_state` (optional) holds the
# previous resource, service, start and status of each row, so a move can be compared with the old appointment.
class Captain::Evals::RoutingBenchmark::BookingChanges
  Row = Struct.new(:record, :change, :previous, keyword_init: true) do
    def id = record.id

    # The person the appointment is for: the patient card when there is one, else the caller.
    def patient_id = record.patient_contact_id || record.contact_id
  end

  attr_reader :rows

  def initialize(account:, before: {}, before_state: nil)
    prior = before.fetch('appointment', {})
    states = before_state&.fetch('appointment', nil) || {}
    @all = Scheduling::Appointment.where(account_id: account.id).includes(:resource, :service, :patient_contact).order(:id).to_a
    @rows = @all.filter_map { |record| row_for(record, prior, states) }
  end

  def created = rows.select { |row| row.change == :created }
  def updated = rows.select { |row| row.change == :updated }
  def cancelled = rows.select { |row| row.change == :cancelled }
  def changed_ids = rows.map(&:id)

  def for_kind(kind)
    { 'create' => created, 'update' => updated, 'cancel' => cancelled }.fetch(kind.to_s)
  end

  # Active (not cancelled) rows that overlap, where at least one of the two changed in this turn.
  #   same_patient_same_slot  the same person, doctor and start twice
  #   same_patient_overlap    the same person booked twice at the same time (any doctor)
  #   resource_overlap        two people booked with one doctor at the same time
  def conflicts
    active = @all.reject { |record| record.status == 'cancelled' }
    active.combination(2).filter_map do |first, second|
      next unless (changed_ids & [first.id, second.id]).any? && overlap?(first, second)

      kind = conflict_kind(first, second)
      { kind: kind, ids: [first.id, second.id] } if kind
    end
  end

  # JSON-friendly description of the changed rows for the report.
  def delta(directory = nil)
    rows.map { |row| describe(row, directory) }
  end

  private

  def row_for(record, prior, states)
    return Row.new(record: record, change: :created) unless prior.key?(record.id)
    return if record.updated_at == prior[record.id]

    previous = states[record.id]
    cancelled = record.status == 'cancelled' && (previous.nil? || previous['status'] != 'cancelled')
    Row.new(record: record, change: cancelled ? :cancelled : :updated, previous: previous)
  end

  def overlap?(first, second)
    first.starts_at < second.ends_at && second.starts_at < first.ends_at
  end

  def conflict_kind(first, second)
    same_patient = patient_of(first) == patient_of(second)
    return 'same_patient_same_slot' if same_patient && first.resource_id == second.resource_id && first.starts_at == second.starts_at
    return 'same_patient_overlap' if same_patient

    'resource_overlap' if first.resource_id == second.resource_id
  end

  def patient_of(record) = record.patient_contact_id || record.contact_id

  def describe(row, directory)
    record = row.record
    zone = record.resource&.timezone || Scheduling::Constants::DEFAULT_TIMEZONE
    {
      id: record.id, change: row.change.to_s, status: record.status,
      resource: directory&.resource_key(record.resource_id) || record.resource&.name,
      service: directory&.service_key(record.service_id) || record.service&.name,
      patient: directory&.contact_key(row.patient_id) || record.client_name,
      starts_at: record.starts_at.in_time_zone(zone).iso8601,
      previous: describe_previous(row.previous, directory, zone)
    }.compact
  end

  def describe_previous(previous, directory, zone)
    return unless previous

    {
      resource: directory&.resource_key(previous['resource_id']) || previous['resource_id'],
      starts_at: previous['starts_at']&.in_time_zone(zone)&.iso8601, status: previous['status']
    }.compact
  end
end
