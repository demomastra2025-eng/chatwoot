require 'rails_helper'

RSpec.describe Crm::Reports::TaskLifecycleQuery do
  let(:account) { create(:account, settings: { 'workspace_timezone' => 'America/New_York' }) }
  let(:status) { create(:crm_task_status, account: account) }
  let(:base_params) { { from_date: '2026-03-08', to_date: '2026-03-09', as_of_date: '2026-03-10' } }
  let(:query) { described_class.new(account: account, tasks_scope: account.crm_tasks, params: base_params) }

  def create_lifecycle_event(task:, type:, at:, after_data:, **attributes)
    create(
      :crm_event,
      account: task.account,
      eventable: task,
      event_type: "task_#{type}",
      created_at: at,
      after_data: after_data,
      **attributes
    )
  end

  def timed_snapshot(type:, terminal_at:, due_at:)
    { 'all_day' => false, 'due_at' => due_at&.iso8601, "#{type}_at" => terminal_at.iso8601 }
  end

  def all_day_snapshot(type:, terminal_at:, due_on:)
    { 'all_day' => true, 'due_on' => due_on.iso8601, "#{type}_at" => terminal_at.iso8601 }
  end

  it 'counts immutable terminal occurrences and preserves reopen cycles without counting reopen events' do
    task = create(:crm_task, account: account, status: status)
    first = create_lifecycle_event(
      task: task,
      type: 'completed',
      at: Time.utc(2026, 3, 8, 12),
      after_data: timed_snapshot(type: 'completed', terminal_at: Time.utc(2026, 3, 8, 12), due_at: Time.utc(2026, 3, 8, 13)),
      command_key: 'complete-1'
    )
    create_lifecycle_event(task: task, type: 'reopened', at: Time.utc(2026, 3, 8, 14), after_data: {})
    second = create_lifecycle_event(
      task: task,
      type: 'completed',
      at: Time.utc(2026, 3, 8, 16),
      after_data: timed_snapshot(type: 'completed', terminal_at: Time.utc(2026, 3, 8, 16), due_at: Time.utc(2026, 3, 8, 15)),
      command_key: 'complete-2'
    )

    aggregate = query.aggregate_rows.fetch(0)

    expect(aggregate).to include(
      lifecycle_type: 'completed', lifecycle_count: 2, overdue_count: 1, on_time_count: 1,
      exact_count: 2, estimated_count: 0, unknown_count: 0, overdue_rate_percent: 50.0
    )
    expect(query.drill_down_rows.pluck(:lifecycle_event_id)).to eq([second.id, first.id])
  end

  it 'consumes canonical retry-deduplicated completion facts across a reopen cycle' do
    account.enable_features!('crm_deals', 'crm_tasks')
    Crm::Bootstrap::AccountService.new(account: account).perform
    actor = create(:user, :administrator, account: account)
    task = create(
      :crm_task,
      account: account,
      status: account.crm_task_statuses.find_by!(category: 'open'),
      due_at: Time.utc(2026, 3, 8, 11),
      all_day: false
    )

    travel_to(Time.utc(2026, 3, 8, 12)) do
      params = { idempotency_key: 'complete-1', lock_version: task.lock_version }
      Crm::Tasks::CompleteService.new(account: account, task: task, actor: actor, params: params).perform
      Crm::Tasks::CompleteService.new(account: account, task: task.reload, actor: actor, params: params).perform
      Crm::Tasks::ReopenService.new(
        account: account,
        task: task.reload,
        actor: actor,
        params: { idempotency_key: 'reopen-1', lock_version: task.lock_version }
      ).perform
    end
    travel_to(Time.utc(2026, 3, 8, 13)) do
      Crm::Tasks::CompleteService.new(
        account: account,
        task: task.reload,
        actor: actor,
        params: { idempotency_key: 'complete-2', lock_version: task.lock_version }
      ).perform
    end

    lifecycle_query = described_class.new(account: account, tasks_scope: account.crm_tasks, params: base_params)

    expect(task.events.where(event_type: 'task_completed').count).to eq(2)
    expect(lifecycle_query.total_count).to eq(2)
    expect(lifecycle_query.aggregate_rows.fetch(0)).to include(lifecycle_count: 2, overdue_count: 2)
  end

  it 'applies timed instants and all-day Workspace dates across the DST boundary' do
    timed = create(:crm_task, account: account, status: status)
    all_day_on_time = create(:crm_task, account: account, status: status)
    all_day_overdue = create(:crm_task, account: account, status: status)
    create_lifecycle_event(
      task: timed,
      type: 'cancelled',
      at: Time.utc(2026, 3, 8, 7, 0, 1),
      after_data: timed_snapshot(type: 'cancelled', terminal_at: Time.utc(2026, 3, 8, 7, 0, 1), due_at: Time.utc(2026, 3, 8, 7))
    )
    create_lifecycle_event(
      task: all_day_on_time,
      type: 'completed',
      at: Time.utc(2026, 3, 9, 3, 59, 59),
      after_data: all_day_snapshot(type: 'completed', terminal_at: Time.utc(2026, 3, 9, 3, 59, 59), due_on: Date.new(2026, 3, 8))
    )
    create_lifecycle_event(
      task: all_day_overdue,
      type: 'completed',
      at: Time.utc(2026, 3, 9, 4),
      after_data: all_day_snapshot(type: 'completed', terminal_at: Time.utc(2026, 3, 9, 4), due_on: Date.new(2026, 3, 8))
    )

    rows = query.drill_down_rows.index_by { |row| row[:task_id] }

    expect(rows.fetch(timed.id)).to include(deadline_state: 'overdue')
    expect(rows.fetch(all_day_on_time.id)).to include(
      deadline_state: 'on_time',
      deadline: include(kind: 'all_day', due_on: '2026-03-08', timezone: 'America/New_York')
    )
    expect(rows.fetch(all_day_overdue.id)).to include(deadline_state: 'overdue')
    expect(query.meta).to include(
      from: '2026-03-08T05:00:00.000000Z',
      to: '2026-03-10T04:00:00.000000Z',
      window_fact: 'terminal_at_with_event_created_at_fallback'
    )
  end

  it 'uses the immutable terminal timestamp rather than delayed event recording time' do
    task = create(:crm_task, account: account, status: status)
    terminal_at = Time.utc(2026, 3, 8, 12)
    create_lifecycle_event(
      task: task,
      type: 'completed',
      at: Time.utc(2026, 3, 8, 14),
      after_data: timed_snapshot(type: 'completed', terminal_at: terminal_at, due_at: Time.utc(2026, 3, 8, 13))
    )

    row = query.drill_down_rows.fetch(0)

    expect(row).to include(lifecycle_at: '2026-03-08T12:00:00.000000Z', deadline_state: 'on_time')
  end

  it 'separates exact, estimated, unknown, not-configured, and unknown deadline reliability' do
    exact = create(:crm_task, account: account, status: status)
    estimated = create(:crm_task, account: account, status: status)
    unknown = create(:crm_task, account: account, status: status)
    missing_deadline = create(:crm_task, account: account, status: status)
    malformed = create(:crm_task, account: account, status: status)
    timestamp = Time.utc(2026, 3, 8, 12)
    create_lifecycle_event(
      task: exact,
      type: 'completed',
      at: timestamp,
      after_data: timed_snapshot(type: 'completed', terminal_at: timestamp, due_at: timestamp + 1.hour)
    )
    create_lifecycle_event(task: estimated, type: 'completed', at: timestamp + 1.hour, after_data: { all_day: true, due_on: '2026-03-08' })
    create_lifecycle_event(
      task: unknown,
      type: 'completed',
      at: timestamp + 2.hours,
      after_data: timed_snapshot(type: 'completed', terminal_at: timestamp + 2.hours, due_at: timestamp + 3.hours),
      schema_version: 2
    )
    create_lifecycle_event(
      task: missing_deadline,
      type: 'completed',
      at: timestamp + 3.hours,
      after_data: timed_snapshot(type: 'completed', terminal_at: timestamp + 3.hours, due_at: nil)
    )
    create_lifecycle_event(
      task: malformed,
      type: 'completed',
      at: timestamp + 4.hours,
      after_data: { 'all_day' => false, 'due_at' => '2026-99-99T99:99:99Z', 'completed_at' => '2026-99-99T99:99:99Z' }
    )
    aggregate = query.aggregate_rows.fetch(0)
    rows = query.drill_down_rows.index_by { |row| row[:task_id] }

    expect(aggregate).to include(
      lifecycle_count: 5, exact_count: 2, estimated_count: 1, unknown_count: 2,
      not_configured_count: 1, unknown_deadline_count: 3, overdue_rate_percent: nil, coverage: 'unknown'
    )
    expect(rows.fetch(estimated.id)).to include(lifecycle_reliability: 'estimated')
    expect(rows.fetch(unknown.id)).to include(lifecycle_reliability: 'unknown')
    expect(rows.fetch(missing_deadline.id)).to include(deadline_state: 'not_configured')
    expect(rows.fetch(malformed.id)).to include(lifecycle_reliability: 'unknown', deadline_state: 'unknown')
    expect(query.meta).to include(
      coverage: 'unknown', source: 'crm_events.task_terminal_lifecycle', definition_version: 1,
      reliable_since: nil, unknown_before: nil, reliability_boundary: 'per_fact_only'
    )
  end

  it 'classifies a syntactically shaped but impossible all-day deadline as unknown' do
    task = create(:crm_task, account: account, status: status)
    timestamp = Time.utc(2026, 3, 8, 12)
    snapshot = all_day_snapshot(type: 'completed', terminal_at: timestamp, due_on: Date.new(2026, 3, 8))
               .merge('due_on' => '2026-02-31')
    create_lifecycle_event(task: task, type: 'completed', at: timestamp, after_data: snapshot)

    row = query.drill_down_rows.fetch(0)
    expect(row).to include(lifecycle_reliability: 'exact', deadline_state: 'unknown')
    expect(row[:deadline]).to include(kind: 'unknown', due_at: nil, due_on: nil)
  end

  it 'does not cast a syntactically shaped but impossible timed deadline' do
    task = create(:crm_task, account: account, status: status)
    timestamp = Time.utc(2026, 3, 8, 12)
    snapshot = timed_snapshot(type: 'completed', terminal_at: timestamp, due_at: timestamp - 1.hour)
               .merge('due_at' => '2026-99-99T99:99:99Z')
    create_lifecycle_event(task: task, type: 'completed', at: timestamp, after_data: snapshot)

    row = query.drill_down_rows.fetch(0)
    expect(row).to include(lifecycle_reliability: 'exact', deadline_state: 'unknown')
    expect(row[:deadline]).to include(kind: 'unknown', due_at: nil, due_on: nil)
  end

  it 'uses one canonical terminal timestamp predicate for cohort time and reliability' do
    task = create(:crm_task, account: account, status: status)
    created_at = Time.utc(2026, 3, 8, 12)
    snapshot = timed_snapshot(type: 'completed', terminal_at: created_at, due_at: created_at + 1.hour)
               .merge('completed_at' => '2026-03-07 12:00:00+00')
    create_lifecycle_event(task: task, type: 'completed', at: created_at, after_data: snapshot)

    row = query.drill_down_rows.fetch(0)

    expect(row).to include(
      lifecycle_at: '2026-03-08T12:00:00.000000Z',
      lifecycle_reliability: 'unknown',
      deadline_state: 'unknown'
    )
  end

  it 'shares one scoped fact relation across aggregates, filters, pagination, and parity' do
    visible = create(:crm_task, account: account, status: status)
    hidden = create(:crm_task, account: account, status: status)
    timestamp = Time.utc(2026, 3, 8, 12)
    [visible, hidden].each do |task|
      create_lifecycle_event(
        task: task,
        type: 'cancelled',
        at: timestamp,
        after_data: timed_snapshot(type: 'cancelled', terminal_at: timestamp, due_at: timestamp - 1.hour)
      )
    end
    scoped_query = described_class.new(
      account: account,
      tasks_scope: account.crm_tasks.where(id: visible.id),
      params: base_params.merge(lifecycle_type: 'cancelled', deadline_state: 'overdue', page: 1, per_page: 1)
    )

    expect(scoped_query.aggregate_rows.sum { |row| row[:lifecycle_count] }).to eq(1)
    expect(scoped_query.pagination_meta).to include(page: 1, per_page: 1, total_count: 1)
    expect(scoped_query.drill_down_rows.pluck(:task_id)).to contain_exactly(visible.id)
  end

  it 'rejects invalid windows, observation dates, filters, and pagination' do
    expectations = [
      [base_params.except(:as_of_date), 'as_of_date is required'],
      [base_params.merge(as_of_date: '2026-03-08'), 'as_of_date must be on or after to_date'],
      [base_params.merge(lifecycle_type: 'reopened'), 'lifecycle_type is invalid'],
      [base_params.merge(deadline_state: 'late'), 'deadline_state is invalid'],
      [base_params.merge(per_page: 101), 'per_page must not exceed 100']
    ]

    expectations.each do |params, message|
      expect do
        report = described_class.new(account: account, tasks_scope: account.crm_tasks, params: params)
        report.pagination_meta if params[:per_page]
      end.to raise_error(Crm::Error, message)
    end
  end
end
