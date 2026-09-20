require 'rails_helper'

RSpec.describe Scheduling::Reports::MeetingsBySpecialistQuery do
  let(:account) { create(:account, settings: { 'workspace_timezone' => 'America/New_York' }) }
  let(:resource) { create(:scheduling_resource, account: account, name: 'Specialist without user') }
  let(:generated_at) { Time.utc(2026, 3, 8, 8, 0) }
  let(:window) { { from_local: '2026-03-08T01:30:00', to_local: '2026-03-08T04:30:00' } }

  def build_query(params = nil, scope: account.scheduling_appointments, **overrides)
    described_class.new(
      account: account,
      appointments_scope: scope,
      params: window.merge(params || {}).merge(overrides),
      generated_at: generated_at
    )
  end

  def create_appointment(resource:, starts_at:, ends_at: starts_at + 30.minutes, **attributes)
    create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      starts_at: starts_at,
      ends_at: ends_at,
      **attributes
    )
  end

  it 'groups every supported status by Resource identity including a specialist without User' do
    zone = ActiveSupport::TimeZone['America/New_York']
    Scheduling::Constants::APPOINTMENT_STATUSES.each_with_index do |status, index|
      starts_at = zone.local(2026, 3, 8, 3, index * 5)
      create_appointment(resource: resource, starts_at: starts_at, status: status)
    end

    row = build_query.aggregate_rows.fetch(0)

    expect(row[:specialist]).to eq(
      id: resource.id,
      name: 'Specialist without user',
      catalog_state: 'current_catalog_projection'
    )
    expect(row[:total_count]).to eq(5)
    expect(row[:status_counts]).to eq(Scheduling::Constants::APPOINTMENT_STATUSES.index_with(1).merge('unknown' => 0))
    expect(row[:scheduled_duration]).to eq(seconds: 9_000, valid_count: 5, invalid_count: 0)
    expect(build_query.meta).to include(
      metric_kind: 'current_projection',
      reliability: 'exact_current_snapshot',
      generated_at: '2026-03-08T08:00:00.000000Z',
      generated_at_local: '2026-03-08T04:00:00.000000-04:00',
      from: '2026-03-08T06:30:00.000000Z',
      to: '2026-03-08T08:30:00.000000Z',
      timezone: 'America/New_York',
      total_count: 5
    )
  end

  it 'uses Workspace-local DST-aware half-open appointment-start boundaries' do
    zone = ActiveSupport::TimeZone['America/New_York']
    included_before_jump = create_appointment(resource: resource, starts_at: zone.local(2026, 3, 8, 1, 30))
    included_after_jump = create_appointment(resource: resource, starts_at: zone.local(2026, 3, 8, 3, 29, 59))
    excluded_at_end = create_appointment(resource: resource, starts_at: zone.local(2026, 3, 8, 4, 30))

    ids = build_query.drill_down_rows.pluck(:appointment_id)

    expect(ids).to eq([included_before_jump.id, included_after_jump.id])
    expect(ids).not_to include(excluded_at_end.id)
  end

  it 'returns an exact zero only for an empty scoped cohort' do
    query = build_query

    expect(query.aggregate_rows).to be_empty
    expect(query.meta).to include(total_count: 0, reliability: 'exact_current_snapshot')
    expect(query.drill_down_rows).to be_empty
    expect(query.pagination_meta[:total_count]).to eq(0)
  end

  it 'reports zero duration separately from malformed negative intervals' do
    starts_at = Time.utc(2026, 3, 8, 7, 15)
    zero = create_appointment(resource: resource, starts_at: starts_at)
    negative = create_appointment(resource: resource, starts_at: starts_at + 1.minute)
    zero.update_columns(ends_at: zero.starts_at) # rubocop:disable Rails/SkipsModelValidations
    negative.update_columns(ends_at: negative.starts_at - 1.minute) # rubocop:disable Rails/SkipsModelValidations

    row = build_query.aggregate_rows.fetch(0)
    details = build_query.drill_down_rows.index_by { |item| item[:appointment_id] }

    expect(row[:scheduled_duration]).to eq(seconds: 0, valid_count: 1, invalid_count: 1)
    expect(details.dig(zero.id, :scheduled_duration)).to eq(state: 'exact', seconds: 0)
    expect(details.dig(negative.id, :scheduled_duration)).to eq(state: 'invalid_interval', seconds: nil)
  end

  it 'uses the same per-appointment whole-second rounding in aggregate and details' do
    first = create_appointment(resource: resource, starts_at: Time.utc(2026, 3, 8, 7, 0))
    second = create_appointment(resource: resource, starts_at: Time.utc(2026, 3, 8, 7, 1))
    first.update_columns(ends_at: first.starts_at + 1.9.seconds) # rubocop:disable Rails/SkipsModelValidations
    second.update_columns(ends_at: second.starts_at + 1.9.seconds) # rubocop:disable Rails/SkipsModelValidations

    query = build_query
    aggregate_seconds = query.aggregate_rows.sum { |row| row.dig(:scheduled_duration, :seconds) }
    detail_seconds = query.drill_down_rows.sum { |row| row.dig(:scheduled_duration, :seconds) }

    expect(aggregate_seconds).to eq(2)
    expect(detail_seconds).to eq(aggregate_seconds)
  end

  it 'labels missing or foreign catalog projections without leaking names' do
    starts_at = Time.utc(2026, 3, 8, 7, 0)
    appointment = create_appointment(resource: resource, starts_at: starts_at)
    foreign_account = create(:account)
    foreign_resource = create(:scheduling_resource, account: foreign_account, name: 'Foreign specialist')
    foreign_team = create(:team, account: foreign_account, name: 'Foreign team')
    foreign_service = create(:scheduling_service, account: foreign_account, name: 'Foreign service')
    appointment.update_columns( # rubocop:disable Rails/SkipsModelValidations
      resource_id: foreign_resource.id,
      team_id: foreign_team.id,
      service_id: foreign_service.id,
      service_name_snapshot: 'Persisted service name'
    )

    row = build_query.drill_down_rows.fetch(0)

    expect(row[:specialist]).to eq(id: foreign_resource.id, name: nil, catalog_state: 'unknown')
    expect(row[:team]).to eq(id: foreign_team.id, name: nil, catalog_state: 'unknown')
    expect(row[:service]).to include(id: foreign_service.id, name: nil, catalog_state: 'unknown')
    expect(row.dig(:service, :snapshot, :name)).to eq('Persisted service name')
    expect(row.to_json).not_to include('Foreign specialist', 'Foreign team', 'Foreign service')
  end

  it 'uses one materialized snapshot for stable pagination, count, and aggregate parity' do
    zone = ActiveSupport::TimeZone['America/New_York']
    appointments = Array.new(3) do |index|
      create_appointment(resource: resource, starts_at: zone.local(2026, 3, 8, 3, index))
    end
    sql = []
    subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |event|
      sql << event.payload[:sql] if event.payload[:sql].include?('matching_appointments AS MATERIALIZED')
    end

    aggregate = build_query
    details = build_query(page: 2, per_page: 2)

    expect(details.drill_down_rows.pluck(:appointment_id)).to eq([appointments.last.id])
    expect(details.pagination_meta).to include(page: 2, per_page: 2, total_count: 3)
    expect(aggregate.aggregate_rows.sum { |row| row[:total_count] }).to eq(details.pagination_meta[:total_count])
    expect(aggregate.meta[:query_fingerprint]).to eq(details.pagination_meta[:query_fingerprint])
    expect(sql.size).to eq(2)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  it 'validates the bounded window, historical params, tenant filters, statuses, and pagination' do
    foreign_resource = create(:scheduling_resource, account: create(:account))

    expect { described_class.new(account: account, appointments_scope: account.scheduling_appointments, params: {}) }
      .to raise_error(Scheduling::Error, 'from_local is required')
    expect { build_query(to_local: '2027-03-10T01:30:01') }
      .to raise_error(Scheduling::Error, 'window must not exceed 366 days')
    expect { build_query(resource_id: foreign_resource.id) }
      .to raise_error(Scheduling::Error, 'resource_id is invalid')
    expect { build_query(status: 'invented') }
      .to raise_error(Scheduling::Error, 'status is invalid: invented')
    expect { build_query(page: 10_001).pagination_meta }
      .to raise_error(Scheduling::Error, 'page must not exceed 10000')
    expect { build_query(as_of: generated_at) }
      .to raise_error(Scheduling::Error, 'as_of is not supported for current projections')
  end

  it 'rejects offsets, invalid dates, and nonexistent or ambiguous DST wall times' do
    invalid_values = [
      '2026-03-08T01:30:00Z',
      '2026-03-08T01:30:00-05:00',
      '2026-02-30T01:30:00',
      '2026-03-08T02:30:00',
      '2026-11-01T01:30:00'
    ]

    invalid_values.each do |from_local|
      expect { build_query(from_local: from_local, to_local: '2026-11-01T03:30:00') }
        .to raise_error(Scheduling::Error, /offset-free|unambiguous existing/)
    end

    precise = build_query(from_local: '2026-03-08T01:30:00.123456')
    expect(precise.from_time.utc.iso8601(6)).to eq('2026-03-08T06:30:00.123456Z')
  end
end
