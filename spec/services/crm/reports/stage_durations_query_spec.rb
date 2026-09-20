require 'rails_helper'

RSpec.describe Crm::Reports::StageDurationsQuery do
  let(:account) { create(:account, settings: { 'workspace_timezone' => 'America/New_York' }) }
  let(:pipeline) { create(:crm_pipeline, account: account, name: 'Sales', code: 'sales') }
  let(:stage) { create(:crm_stage, account: account, pipeline: pipeline, name: 'Qualified', code: 'qualified') }
  let(:base_params) { { from_date: '2026-03-08', to_date: '2026-03-08' } }
  let(:query) { described_class.new(account: account, deals_scope: account.crm_deals, params: base_params) }

  def create_visit(entered_at:, duration:, **attributes)
    estimated = attributes.fetch(:estimated, false)
    reliable_since = attributes.fetch(:reliable_since, entered_at)
    visit_stage = attributes.fetch(:visit_stage, stage)
    deal = attributes[:deal] || create(:crm_deal, account: account, pipeline: visit_stage.pipeline, stage: visit_stage)
    create(
      :crm_stage_visit,
      account: account,
      deal: deal,
      pipeline: visit_stage.pipeline,
      stage: visit_stage,
      entered_at: entered_at,
      exited_at: entered_at + duration,
      estimated: estimated,
      reliable_since: reliable_since
    )
  end

  it 'has an account-scoped partial index for completed-visit windows' do
    index = ActiveRecord::Base.connection.indexes(:crm_stage_visits).find do |candidate|
      candidate.name == 'index_crm_stage_visits_on_account_id_and_exited_at'
    end

    expect(index).to have_attributes(
      columns: %w[account_id exited_at],
      where: '(exited_at IS NOT NULL)'
    )
  end

  it 'calculates deterministic continuous median and P75 for an even mixed dataset' do
    entered_at = Time.utc(2026, 3, 8, 8)
    [0, 1.hour, 2.hours].each { |duration| create_visit(entered_at: entered_at, duration: duration) }
    create_visit(entered_at: entered_at, duration: 3.hours, estimated: true)

    row = query.aggregate_rows.fetch(0)

    expect(row).to include(
      total_count: 4,
      exact_count: 3,
      estimated_count: 1,
      median_duration_seconds: 5400.0,
      p75_duration_seconds: 8100.0,
      exact_duration_seconds: { count: 3, median: 3600.0, p75: 5400.0 },
      estimated_duration_seconds: { count: 1, median: 10_800.0, p75: 10_800.0 }
    )
  end

  it 'calculates deterministic continuous percentiles for an odd dataset' do
    entered_at = Time.utc(2026, 3, 8, 8)
    [0, 1.hour, 2.hours].each { |duration| create_visit(entered_at: entered_at, duration: duration) }

    expect(query.aggregate_rows.fetch(0)).to include(
      median_duration_seconds: 3600.0,
      p75_duration_seconds: 5400.0,
      estimated_duration_seconds: { count: 0, median: nil, p75: nil }
    )
  end

  it 'uses lower-inclusive upper-exclusive histogram boundaries including legitimate zero' do
    completed_at = Time.utc(2026, 3, 8, 18)
    [0, 1.hour, 4.hours, 1.day, 3.days, 7.days, 30.days].each do |duration|
      create_visit(entered_at: completed_at - duration, duration: duration)
    end

    histogram = query.aggregate_rows.fetch(0).fetch(:histogram)

    expect(histogram.pluck(:key, :count)).to eq(
      [
        ['under_1_hour', 1],
        ['1_to_4_hours', 1],
        ['4_to_24_hours', 1],
        ['1_to_3_days', 1],
        ['3_to_7_days', 1],
        ['7_to_30_days', 1],
        ['30_days_or_more', 1]
      ]
    )
  end

  it 'uses exited_at completion window across DST and returns normalized UTC and local bounds' do
    included = create_visit(entered_at: Time.utc(2026, 3, 9, 2, 59, 59), duration: 1.hour)
    create_visit(entered_at: Time.utc(2026, 3, 9, 3), duration: 1.hour)

    expect(query.drill_down_rows.pluck(:stage_visit_id)).to eq([included.id])
    expect(query.meta).to include(
      timezone: 'America/New_York',
      from: '2026-03-08T05:00:00.000000Z',
      to: '2026-03-09T04:00:00.000000Z',
      from_local: '2026-03-08T00:00:00.000000-05:00',
      to_local: '2026-03-09T00:00:00.000000-04:00',
      window_fact: 'exited_at'
    )
  end

  it 'excludes ongoing visits without fabricating zero and reports them explicitly' do
    completed = create_visit(entered_at: Time.utc(2026, 3, 8, 8), duration: 1.hour)
    ongoing_deal = create(:crm_deal, account: account, pipeline: pipeline, stage: stage)
    create(:crm_stage_visit, account: account, deal: ongoing_deal, pipeline: pipeline, stage: stage, entered_at: Time.utc(2026, 3, 8, 9))

    expect(query.drill_down_rows.pluck(:stage_visit_id)).to eq([completed.id])
    expect(query.pagination_meta).to include(total_count: 1, ongoing_excluded_count: 1)
  end

  it 'marks pre-reliability history unknown without coercing its duration to zero' do
    entered_at = Time.utc(2026, 3, 8, 8)
    create_visit(entered_at: entered_at, duration: 1.hour, reliable_since: Time.utc(2026, 3, 1))
    visit = create_visit(entered_at: entered_at, duration: 2.hours, reliable_since: entered_at + 3.hours)

    expect(query.drill_down_rows).to contain_exactly(
      include(duration_seconds: 3600, coverage: 'exact'),
      include(stage_visit_id: visit.id, duration_seconds: 7200, reliability: 'exact', coverage: 'unknown_before')
    )
    expect(query.aggregate_rows.fetch(0)).to include(coverage: 'unknown_before', median_duration_seconds: 5400.0)
    expect(query.meta).to include(coverage: 'unknown_before')
  end

  it 'excludes impossible negative intervals and surfaces the corrupt count contract' do
    visit = create_visit(entered_at: Time.utc(2026, 3, 8, 8), duration: 1.hour)
    ActiveRecord::Base.connection.execute(
      'ALTER TABLE crm_stage_visits DROP CONSTRAINT crm_stage_visits_valid_interval'
    )
    visit.update_columns(exited_at: visit.entered_at - 1.second) # rubocop:disable Rails/SkipsModelValidations

    expect(query.total_count).to eq(0)
    expect(query.meta).to include(negative_interval_excluded_count: 1)
  end

  it 'shares scoped facts across aggregate, filters, pagination, archived deals, and count parity' do
    visible_deal = create(:crm_deal, account: account, pipeline: pipeline, stage: stage)
    archived_deal = create(:crm_deal, account: account, pipeline: pipeline, stage: stage, archived_at: Time.current)
    hidden_deal = create(:crm_deal, account: account, pipeline: pipeline, stage: stage)
    timestamp = Time.utc(2026, 3, 8, 8)
    [visible_deal, archived_deal, hidden_deal].each do |deal|
      create_visit(entered_at: timestamp, duration: 1.hour, deal: deal)
    end

    scoped_query = described_class.new(
      account: account,
      deals_scope: account.crm_deals.where(id: [visible_deal.id, archived_deal.id]),
      params: base_params.merge(pipeline_id: pipeline.id, stage_id: stage.id, page: 2, per_page: 1)
    )

    expect(scoped_query.aggregate_rows.sum { |row| row[:total_count] }).to eq(2)
    expect(scoped_query.pagination_meta).to include(page: 2, per_page: 1, total_count: 2)
    expect(scoped_query.drill_down_rows.pluck(:deal_id)).to contain_exactly(visible_deal.id)
  end

  it 'rejects invalid, oversized, paginated, mismatched, and foreign-account filters' do
    other_pipeline = create(:crm_pipeline, account: account)
    other_stage = create(:crm_stage, account: account, pipeline: other_pipeline)
    foreign_stage = create(:crm_stage)
    expectations = [
      [{ from_date: '2026-02-30', to_date: '2026-03-01' }, 'from_date must be a valid date'],
      [{ from_date: '2025-01-01', to_date: '2026-03-01' }, 'date window must not exceed 366 days'],
      [base_params.merge(per_page: 101), 'per_page must not exceed 100'],
      [base_params.merge(pipeline_id: pipeline.id, stage_id: other_stage.id), 'stage_id does not belong to pipeline_id'],
      [base_params.merge(stage_id: foreign_stage.id), 'stage filter is invalid']
    ]

    expectations.each do |params, message|
      expect do
        report = described_class.new(account: account, deals_scope: account.crm_deals, params: params)
        report.pagination_meta if params[:per_page]
      end.to raise_error(Crm::Error, message)
    end
  end
end
