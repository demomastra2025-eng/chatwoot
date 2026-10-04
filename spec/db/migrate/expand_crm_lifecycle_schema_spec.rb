require 'rails_helper'
require Rails.root.join('db/migrate/20261004120000_expand_crm_lifecycle_schema')

RSpec.describe ExpandCrmLifecycleSchema do
  it 'backfills legacy task timezones and preserves task state and historical deadlines' do
    start_at = Time.utc(2025, 2, 3, 10, 15)
    due_at = Time.utc(2025, 2, 3, 11, 45)
    settings_cases = [
      [{}, 'Asia/Almaty'],
      [{ 'reporting_timezone' => nil }, 'Asia/Almaty'],
      [{ 'reporting_timezone' => '' }, 'Asia/Almaty'],
      [{ 'reporting_timezone' => '   ' }, 'Asia/Almaty'],
      [{ 'reporting_timezone' => 'Not/A_Real_Zone' }, 'Asia/Almaty'],
      [{ 'reporting_timezone' => 'Europe/Berlin' }, 'Europe/Berlin'],
      [{ 'reporting_timezone' => 'Eastern Time (US & Canada)' }, 'America/New_York']
    ]
    task_expectations = settings_cases.map do |settings, expected_timezone|
      account = create(:account)
      task = create(
        :crm_task,
        account: account,
        outcome: 'completed',
        start_at: start_at,
        due_at: due_at
      )
      account.update_columns(settings: settings) # rubocop:disable Rails/SkipsModelValidations -- recreate stored legacy settings rejected by current validation

      [task, expected_timezone, task.status_id]
    end

    described_class.new.send(:backfill_account_timezones)

    task_expectations.each do |task, expected_timezone, status_id|
      expect(task.reload).to have_attributes(
        schedule_timezone: expected_timezone,
        status_id: status_id,
        outcome: 'completed',
        all_day: false,
        due_on: nil,
        start_at: start_at,
        due_at: due_at
      )
    end
  end

  it 'upgrades legacy stage visits without changing history and remains idempotent' do
    connection = ActiveRecord::Base.connection
    account = create(:account)
    pipeline = create(:crm_pipeline, account: account)
    stage = create(:crm_stage, account: account, pipeline: pipeline)
    deal = create(:crm_deal, account: account, pipeline: pipeline, stage: stage)
    backfill_deal = create(:crm_deal, account: account, pipeline: pipeline, stage: stage)
    closed_at = Time.utc(2024, 1, 5, 12, 30)
    first_entered_at = Time.utc(2024, 1, 3, 9)
    closed_visit = create(
      :crm_stage_visit,
      deal: deal,
      entered_at: first_entered_at,
      exited_at: closed_at,
      reliable_since: first_entered_at,
      correlation_id: '96000451-0000-4000-8000-000000000001'
    )
    active_visit = create(
      :crm_stage_visit,
      deal: deal,
      entered_at: closed_at,
      reliable_since: closed_at,
      correlation_id: '96000452-0000-4000-8000-000000000002'
    )
    existing_rows = [closed_visit, active_visit].map { |visit| visit.reload.attributes }

    connection.remove_check_constraint(:crm_stage_visits, name: 'crm_stage_visits_terminal_attribution_valid')
    %i[owner_id_at_terminal team_id_at_terminal terminal_attribution_version].each do |column|
      connection.remove_column(:crm_stage_visits, column)
    end
    connection.change_column_default(:crm_stage_visits, :correlation_id, nil)
    connection.schema_cache.clear_data_source_cache!('crm_stage_visits')
    Crm::StageVisit.reset_column_information

    migration = described_class.new
    2.times { migration.send(:create_stage_visits) }
    connection.schema_cache.clear_data_source_cache!('crm_stage_visits')
    Crm::StageVisit.reset_column_information

    expect(Crm::StageVisit.where(deal_id: deal.id).order(:id).map(&:attributes)).to eq(existing_rows)
    backfilled_visits = Crm::StageVisit.where(deal_id: backfill_deal.id)
    expect(backfilled_visits.count).to eq(1)
    expect(backfilled_visits.first).to have_attributes(
      account_id: account.id,
      stage_id: stage.id,
      estimated: true,
      exited_at: nil,
      terminal_attribution_version: nil,
      owner_id_at_terminal: nil,
      team_id_at_terminal: nil
    )

    columns = connection.columns(:crm_stage_visits).index_by(&:name)
    attribution_columns = columns.values_at(
      'owner_id_at_terminal',
      'team_id_at_terminal',
      'terminal_attribution_version'
    )
    expect(attribution_columns.map(&:sql_type)).to eq(%w[bigint bigint integer])
    expect(attribution_columns.map(&:null)).to eq([true, true, true])
    expect(attribution_columns.map(&:default)).to eq([nil, nil, nil])
    correlation_id_column = columns['correlation_id']
    expect(correlation_id_column.default_function || correlation_id_column.default).to eq('gen_random_uuid()')
    expect(connection.check_constraints(:crm_stage_visits).map(&:name)).to include(
      'crm_stage_visits_valid_interval',
      'crm_stage_visits_terminal_attribution_valid'
    )
  end
end
