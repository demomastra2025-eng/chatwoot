require 'rails_helper'

RSpec.describe Crm::Reports::TaskResultsQuery do
  let(:account) { create(:account, settings: { 'workspace_timezone' => 'America/New_York' }) }
  let(:status) { create(:crm_task_status, account: account) }
  let(:task_type) { create(:crm_task_type, account: account, code: 'call', name: 'Call') }
  let(:outcome) { create(:crm_task_outcome, account: account, task_type: task_type, code: 'answered', name: 'Answered') }
  let(:base_params) { { from_date: '2026-03-08', to_date: '2026-03-09', as_of_date: '2026-03-10' } }

  def create_result_event(task:, type: 'completed', at: Time.utc(2026, 3, 8, 12), snapshot: {}, **attributes)
    terminal_key = type == 'completed' ? 'completed_at' : 'cancelled_at'
    create(
      :crm_event,
      account: task.account,
      eventable: task,
      event_type: "task_#{type}",
      created_at: at,
      after_data: {
        terminal_key => at.iso8601,
        'all_day' => false,
        'due_at' => (at + 1.hour).iso8601
      }.merge(snapshot),
      **attributes
    )
  end

  def query(params = base_params, scope: account.crm_tasks)
    described_class.new(account: account, tasks_scope: scope, params: params)
  end

  it 'groups immutable terminal occurrences by validated catalog identities with aggregate and details parity' do
    task = create(:crm_task, account: account, status: status, task_type: task_type, task_outcome: outcome, outcome: outcome.code)
    first = create_result_event(
      task: task,
      snapshot: { 'task_type_id' => task_type.id, 'task_outcome_id' => outcome.id, 'outcome' => outcome.code }
    )
    second = create_result_event(
      task: task,
      type: 'cancelled',
      at: Time.utc(2026, 3, 8, 13),
      snapshot: { 'task_type_id' => task_type.id, 'task_outcome_id' => outcome.id, 'outcome' => outcome.code }
    )

    rows = query.aggregate_rows
    details = query.drill_down_rows

    expect(rows.sum { |row| row[:occurrence_count] }).to eq(2)
    expect(rows).to contain_exactly(
      include(lifecycle_type: 'completed', occurrence_count: 1, exact_count: 1, coverage: 'exact'),
      include(lifecycle_type: 'cancelled', occurrence_count: 1, exact_count: 1, coverage: 'exact')
    )
    expect(details.pluck(:lifecycle_event_id)).to eq([second.id, first.id])
    expect(details).to all(
      include(
        task_type: include(id: task_type.id, code: 'call', reliability: 'exact', label_semantics: 'current_catalog_projection'),
        task_outcome: include(id: outcome.id, code: 'answered', reliability: 'exact'),
        reliability: 'exact'
      )
    )
    expect(query.pagination_meta[:total_count]).to eq(rows.sum { |row| row[:occurrence_count] })
  end

  it 'keeps stable foreign-key identity across catalog renames and marks labels as current projections' do
    task = create(:crm_task, account: account, status: status, task_type: task_type, task_outcome: outcome, outcome: outcome.code)
    create_result_event(
      task: task,
      snapshot: { 'task_type_id' => task_type.id, 'task_outcome_id' => outcome.id, 'outcome' => outcome.code }
    )
    task_type.update!(name: 'Renamed call', code: 'renamed_call')
    outcome.update!(name: 'Renamed answer', code: 'renamed_answer')
    create(:crm_task_type, account: account, name: 'Reused call code', code: 'call')
    create(:crm_task_outcome, account: account, task_type: task_type, name: 'Reused answer code', code: 'answered')

    row = query.drill_down_rows.fetch(0)

    expect(row[:task_type]).to include(id: task_type.id, code: 'renamed_call', name: 'Renamed call', reliability: 'exact')
    expect(row[:task_outcome]).to include(id: outcome.id, code: 'renamed_answer', name: 'Renamed answer', reliability: 'exact')
    expect(query.meta).to include(
      catalog_label_definition: 'current_catalog_projection_not_historical_name_or_code_snapshot',
      reliability_boundary: 'per_fact_only', reliable_since: nil
    )
  end

  it 'separates legacy outcome snapshots, missing type identity, and malformed catalog references from exact facts' do
    task = create(:crm_task, account: account, status: status, task_type: task_type)
    legacy = create_result_event(task: task, snapshot: { 'task_type_id' => nil, 'task_outcome_id' => nil, 'outcome' => 'provider_custom' })
    malformed = create_result_event(
      task: task,
      at: Time.utc(2026, 3, 8, 13),
      snapshot: { 'task_type_id' => 'not-an-id', 'task_outcome_id' => '999999999999999999999999', 'outcome' => 'answered' }
    )

    rows = query.drill_down_rows.index_by { |row| row[:lifecycle_event_id] }

    expect(rows.fetch(legacy.id)).to include(
      task_type: include(kind: 'unknown', reliability: 'unknown', source: 'terminal_event.missing_task_type_id'),
      task_outcome: include(kind: 'legacy_snapshot', code: 'provider_custom', reliability: 'estimated'),
      reliability: 'unknown'
    )
    expect(rows.fetch(malformed.id)).to include(
      task_type: include(kind: 'unknown', reliability: 'unknown', source: 'terminal_event.invalid_task_type_id'),
      task_outcome: include(kind: 'unknown', reliability: 'unknown', source: 'terminal_event.invalid_task_outcome_id'),
      reliability: 'unknown'
    )
    expect(query.meta[:coverage]).to eq('unknown')
  end

  it 'combines catalog and lifecycle reliability without presenting fallback timestamps as exact' do
    task = create(:crm_task, account: account, status: status, task_type: task_type, task_outcome: outcome)
    snapshot = {
      'task_type_id' => task_type.id,
      'task_outcome_id' => outcome.id,
      'outcome' => outcome.code,
      'all_day' => false,
      'due_at' => Time.utc(2026, 3, 8, 13).iso8601
    }
    estimated = create(
      :crm_event,
      account: account,
      eventable: task,
      event_type: 'task_completed',
      created_at: Time.utc(2026, 3, 8, 12),
      after_data: snapshot
    )
    unknown = create_result_event(
      task: task,
      at: Time.utc(2026, 3, 8, 14),
      snapshot: snapshot,
      schema_version: 2
    )

    rows = query.drill_down_rows.index_by { |row| row[:lifecycle_event_id] }

    expect(rows.fetch(estimated.id)).to include(reliability: 'estimated')
    expect(rows.fetch(unknown.id)).to include(reliability: 'unknown')
  end

  it 'treats a canonical cancellation without an outcome as exact not-configured rather than a fabricated catalog result' do
    task = create(:crm_task, account: account, status: status, task_type: task_type)
    event = create_result_event(
      task: task,
      type: 'cancelled',
      snapshot: { 'task_type_id' => task_type.id, 'task_outcome_id' => nil, 'outcome' => nil }
    )

    row = query.drill_down_rows.fetch(0)

    expect(row).to include(
      lifecycle_event_id: event.id,
      task_outcome: include(kind: 'not_configured', reliability: 'exact', code: nil),
      reliability: 'exact'
    )
  end

  it 'uses one scoped fact relation for filters, pagination, and repeated terminal cycles' do
    visible = create(:crm_task, account: account, status: status, task_type: task_type)
    hidden = create(:crm_task, account: account, status: status, task_type: task_type)
    [visible, hidden].each do |task|
      create_result_event(
        task: task,
        snapshot: { 'task_type_id' => task_type.id, 'task_outcome_id' => outcome.id, 'outcome' => outcome.code }
      )
    end
    second_visible = create_result_event(
      task: visible,
      at: Time.utc(2026, 3, 8, 14),
      snapshot: { 'task_type_id' => task_type.id, 'task_outcome_id' => outcome.id, 'outcome' => outcome.code }
    )
    filtered = query(
      base_params.merge(task_type_id: task_type.id, task_outcome_id: outcome.id, lifecycle_type: 'completed', reliability: 'exact', per_page: 1),
      scope: account.crm_tasks.where(id: visible.id)
    )

    expect(filtered.aggregate_rows.sum { |row| row[:occurrence_count] }).to eq(2)
    expect(filtered.pagination_meta).to include(page: 1, per_page: 1, total_count: 2)
    expect(filtered.drill_down_rows.pluck(:lifecycle_event_id)).to eq([second_visible.id])
  end

  it 'consumes retry-deduplicated canonical snapshots across reopen cycles' do
    account.enable_features!('crm_deals', 'crm_tasks')
    Crm::Bootstrap::AccountService.new(account: account).perform
    actor = create(:user, :administrator, account: account)
    open_status = account.crm_task_statuses.find_by!(category: 'open')
    canonical_type = account.crm_task_types.find_by!(code: 'call')
    canonical_outcome = canonical_type.outcomes.find_by!(code: 'answered')
    task = create(:crm_task, account: account, status: open_status, task_type: canonical_type)

    travel_to(Time.utc(2026, 3, 8, 12)) do
      params = {
        idempotency_key: 'complete-1', lock_version: task.lock_version,
        task_outcome_id: canonical_outcome.id
      }
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
        params: {
          idempotency_key: 'complete-2', lock_version: task.lock_version,
          task_outcome_id: canonical_outcome.id
        }
      ).perform
    end
    report = described_class.new(account: account, tasks_scope: account.crm_tasks, params: base_params)

    expect(task.events.where(event_type: 'task_completed').count).to eq(2)
    expect(report.total_count).to eq(2)
    expect(report.aggregate_rows.sum { |row| row[:occurrence_count] }).to eq(2)
    expect(report.drill_down_rows).to all(
      include(
        task_type: include(id: canonical_type.id, reliability: 'exact'),
        task_outcome: include(id: canonical_outcome.id, reliability: 'exact'),
        reliability: 'exact'
      )
    )
  end

  it 'rejects foreign, mismatched, malformed, and unbounded filters' do
    other_account = create(:account)
    foreign_type = create(:crm_task_type, account: other_account)
    other_type = create(:crm_task_type, account: account)
    mismatched_outcome = create(:crm_task_outcome, account: account, task_type: other_type)
    expectations = [
      [base_params.merge(task_type_id: foreign_type.id), 'task_type_id is invalid'],
      [base_params.merge(task_type_id: task_type.id, task_outcome_id: mismatched_outcome.id),
       'task_outcome_id does not belong to task_type_id'],
      [base_params.merge(task_type_id: 'structured'), 'task_type_id must be a positive integer'],
      [base_params.merge(reliability: 'inferred'), 'reliability is invalid'],
      [base_params.merge(per_page: 101), 'per_page must not exceed 100']
    ]

    expectations.each do |params, message|
      expect do
        report = query(params)
        report.pagination_meta if params[:per_page]
      end.to raise_error(Crm::Error, message)
    end
  end
end
