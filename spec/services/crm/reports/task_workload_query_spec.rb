require 'rails_helper'

RSpec.describe Crm::Reports::TaskWorkloadQuery do
  let(:account) { create(:account, settings: { 'workspace_timezone' => 'America/New_York' }) }
  let(:generated_at) { Time.utc(2026, 3, 8, 7, 30) }
  let(:open_status) { create(:crm_task_status, account: account, category: 'open') }
  let(:task_type) { create(:crm_task_type, account: account) }

  def create_task(**attributes)
    create(:crm_task, { account: account, status: open_status, task_type: task_type }.merge(attributes))
  end

  def build_query(params = {}, scope: account.crm_tasks)
    described_class.new(account: account, tasks_scope: scope, params: params, generated_at: generated_at)
  end

  it 'returns independent assignee and Team dimensions with mutually exclusive due states' do
    assignee = create(:user, account: account, name: 'Assignee')
    team = create(:team, account: account, name: 'Team')
    create_task(assignee: assignee, team: team, due_at: generated_at - 1.second)
    create_task(assignee: assignee, due_at: generated_at + 1.hour)
    create_task(team: team, all_day: true, due_on: Date.new(2026, 3, 9))
    create_task

    rows = build_query.aggregate_rows.index_by { |row| [row[:dimension], row.dig(:attribution, :id)] }

    expect(rows.fetch(['assignee', assignee.id])).to include(open_count: 2, overdue_count: 1, today_count: 1)
    expect(rows.fetch(['assignee', nil])).to include(open_count: 2, future_count: 1, unscheduled_count: 1)
    expect(rows.fetch(['team', team.id])).to include(open_count: 2, overdue_count: 1, future_count: 1)
    expect(rows.fetch(['team', nil])).to include(open_count: 2, today_count: 1, unscheduled_count: 1)
    expect(rows.values).to all(satisfy do |row|
      row[:open_count] == row.values_at(:overdue_count, :today_count, :future_count, :unscheduled_count, :unknown_count).sum
    end)
  end

  it 'uses instant boundaries for timed deadlines and Workspace date across the DST change' do
    overdue = create_task(due_at: generated_at - Rational(1, 1_000_000), schedule_timezone: 'Asia/Almaty')
    today = create_task(due_at: generated_at, schedule_timezone: 'Asia/Almaty')
    future = create_task(due_at: Time.utc(2026, 3, 9, 4, 0), schedule_timezone: 'Pacific/Auckland')

    rows = build_query({ dimension: 'assignee', assignee_id: 'unassigned' }).drill_down_rows.index_by { |row| row[:task_id] }

    expect(rows.fetch(overdue.id)[:due_state]).to eq('overdue')
    expect(rows.fetch(today.id)[:due_state]).to eq('today')
    expect(rows.fetch(future.id)[:due_state]).to eq('future')
    expect(build_query.meta).to include(workspace_date: '2026-03-08', timezone: 'America/New_York')
  end

  it 'uses the Workspace date for all-day deadlines and ignores schedule_timezone for bucketing' do
    overdue = create_task(all_day: true, due_on: Date.new(2026, 3, 7), schedule_timezone: 'Asia/Almaty')
    today = create_task(all_day: true, due_on: Date.new(2026, 3, 8), schedule_timezone: 'Pacific/Auckland')
    future = create_task(all_day: true, due_on: Date.new(2026, 3, 9), schedule_timezone: 'UTC')

    states = build_query.drill_down_rows.to_h { |row| [row[:task_id], row[:due_state]] }

    expect(states).to include(overdue.id => 'overdue', today.id => 'today', future.id => 'future')
  end

  it 'keeps persisted Team attribution despite current membership drift' do
    assignee = create(:user, account: account)
    persisted_team = create(:team, account: account)
    current_team = create(:team, account: account)
    create(:team_member, team: current_team, user: assignee)
    create_task(assignee: assignee, team: persisted_team)

    expect(build_query({ dimension: 'team' }).aggregate_rows).to contain_exactly(
      include(attribution: include(id: persisted_team.id), open_count: 1)
    )
  end

  it 'excludes terminal and archived Tasks while a reopened current row is included' do
    done_status = create(:crm_task_status, account: account, category: 'done')
    cancelled_status = create(:crm_task_status, account: account, category: 'cancelled')
    create_task(status: done_status, completed_at: generated_at)
    create_task(status: cancelled_status, cancelled_at: generated_at, cancellation_reason: 'No longer needed')
    create_task(archived_at: generated_at)
    reopened = create_task(completed_at: nil, cancelled_at: nil)

    query = build_query

    expect(query.drill_down_rows.pluck(:task_id)).to eq([reopened.id])
    expect(query.meta[:total_count]).to eq(1)
  end

  it 'uses tenant-safe catalogs and projects corrupt attribution as unknown without labels' do
    foreign_account = create(:account)
    foreign_assignee = create(:user, account: foreign_account, name: 'Foreign assignee')
    foreign_team = create(:team, account: foreign_account, name: 'Foreign team')
    foreign_status = create(:crm_task_status, account: foreign_account, category: 'open', name: 'Foreign status')
    foreign_type = create(:crm_task_type, account: foreign_account, name: 'Foreign type')
    visible = create_task
    visible.update_columns(assignee_id: foreign_assignee.id, team_id: foreign_team.id) # rubocop:disable Rails/SkipsModelValidations
    corrupt_status = create_task
    corrupt_status.update_columns(status_id: foreign_status.id) # rubocop:disable Rails/SkipsModelValidations
    corrupt_type = create_task
    corrupt_type.update_columns(task_type_id: foreign_type.id) # rubocop:disable Rails/SkipsModelValidations

    details = build_query.drill_down_rows

    expect(details).to contain_exactly(
      include(task_id: visible.id, assignee: include(id: foreign_assignee.id, name: nil, state: 'unknown'),
              team: include(id: foreign_team.id, name: nil, state: 'unknown')),
      include(task_id: corrupt_type.id, task_type: include(id: foreign_type.id, name: nil, state: 'unknown'))
    )
    expect(details.pluck(:task_id)).not_to include(corrupt_status.id)
    expect(details.to_json).not_to include('Foreign assignee', 'Foreign team', 'Foreign status', 'Foreign type')
  end

  it 'shares filters, fingerprint, and a materialized snapshot across aggregate and details' do
    assignee = create(:user, account: account)
    matching = create_task(assignee: assignee, due_at: generated_at)
    create_task(assignee: assignee, due_at: generated_at - 1.hour)
    sql = []
    subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |event|
      sql << event.payload[:sql] if event.payload[:sql].include?('matching_tasks AS MATERIALIZED')
    end
    filters = { dimension: 'assignee', assignee_id: assignee.id, status_id: open_status.id,
                task_type_id: task_type.id, due_state: 'today' }
    aggregate = build_query(filters)
    details = build_query(filters.merge(page: 1, per_page: 1))

    expect(aggregate.aggregate_rows).to contain_exactly(include(open_count: 1, today_count: 1))
    expect(details.drill_down_rows.pluck(:task_id)).to eq([matching.id])
    expect(details.pagination_meta[:total_count]).to eq(1)
    expect(aggregate.meta[:query_fingerprint]).to eq(details.pagination_meta[:query_fingerprint])
    expect(sql.size).to eq(2)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  it 'returns exact empty zero' do
    query = build_query
    expect(query.aggregate_rows).to be_empty
    expect(query.meta).to include(total_count: 0, reliability: 'exact', historical_attribution: 'unknown_not_supported')
  end

  it 'rejects historical, incoherent, foreign, and unbounded inputs' do
    foreign_assignee = create(:user, account: create(:account))
    expect { build_query({ as_of: generated_at }) }.to raise_error(Crm::Error, 'as_of is not supported for current snapshots')
    expect { build_query({ dimension: 'owner' }) }.to raise_error(Crm::Error, 'dimension must be assignee or team')
    expect { build_query({ assignee_id: 1 }) }.to raise_error(Crm::Error, 'dimension=assignee is required with assignee_id')
    expect { build_query({ dimension: 'assignee', assignee_id: foreign_assignee.id }) }.to raise_error(Crm::Error, 'assignee_id is invalid')
    expect { build_query({ due_state: 'late' }) }.to raise_error(Crm::Error, 'due_state is invalid')
    expect { build_query({ page: 10_001 }).pagination_meta }.to raise_error(Crm::Error, 'page must not exceed 10000')
  end

  it 'keeps malformed deadline facts explicit as unknown while the database constraint prevents persisted invalid shapes' do
    constraint = ActiveRecord::Base.connection.check_constraints(:crm_tasks).find { |item| item.name == 'crm_tasks_deadline_shape' }

    expect(constraint).to be_present
    expect(described_class::DUE_STATES).to include('unknown')
  end
end
