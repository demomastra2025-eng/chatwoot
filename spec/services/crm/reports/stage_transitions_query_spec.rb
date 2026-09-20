require 'rails_helper'

RSpec.describe Crm::Reports::StageTransitionsQuery do
  let(:account) { create(:account, settings: { 'workspace_timezone' => 'America/New_York' }) }
  let(:pipeline) { create(:crm_pipeline, account: account, name: 'Sales', code: 'sales') }
  let(:new_stage) { create(:crm_stage, account: account, pipeline: pipeline, name: 'New', code: 'new') }
  let(:qualified_stage) { create(:crm_stage, account: account, pipeline: pipeline, name: 'Qualified', code: 'qualified') }
  let(:won_stage) { create(:crm_stage, account: account, pipeline: pipeline, name: 'Won', code: 'won', outcome: 'won') }
  let(:deal) { create(:crm_deal, account: account, pipeline: pipeline, stage: won_stage) }
  let(:base_params) { { from_date: '2026-03-08', to_date: '2026-03-08' } }
  let(:query) { described_class.new(account: account, deals_scope: account.crm_deals, params: base_params) }

  def create_visit(deal:, stage:, entered_at:, **attributes)
    create(
      :crm_stage_visit,
      account: deal.account,
      deal: deal,
      pipeline: stage.pipeline,
      stage: stage,
      entered_at: entered_at,
      reliable_since: entered_at,
      **attributes
    )
  end

  it 'excludes initial visits and pairs equal timestamps by id' do
    timestamp = Time.utc(2026, 3, 8, 12)
    first = create_visit(deal: deal, stage: new_stage, entered_at: timestamp - 1.hour, exited_at: timestamp)
    second = create_visit(deal: deal, stage: qualified_stage, entered_at: timestamp, exited_at: timestamp)
    third = create_visit(deal: deal, stage: won_stage, entered_at: timestamp)

    rows = query.drill_down_rows.sort_by { |row| row[:transition_visit_id] }

    expect(rows.pluck(:transition_visit_id)).to eq([second.id, third.id])
    expect(rows.pluck(:from)).to match(
      [
        hash_including(stage_id: first.stage_id, stage_name: 'New'),
        hash_including(stage_id: second.stage_id, stage_name: 'Qualified')
      ]
    )
    expect(query.total_count).to eq(2)
  end

  it 'classifies a transition as estimated when its repaired predecessor is estimated' do
    entered_at = Time.utc(2026, 3, 8, 10)
    create_visit(
      deal: deal,
      stage: new_stage,
      entered_at: entered_at - 1.hour,
      exited_at: entered_at,
      estimated: true
    )
    destination = create_visit(deal: deal, stage: qualified_stage, entered_at: entered_at)

    row = query.drill_down_rows.fetch(0)
    aggregate = query.aggregate_rows.fetch(0)

    expect(row).to include(
      transition_visit_id: destination.id,
      reliability: 'estimated',
      coverage: 'estimated'
    )
    expect(aggregate).to include(total_count: 1, exact_count: 0, estimated_count: 1)
  end

  it 'marks persisted facts before their reliability boundary as unknown history' do
    entered_at = Time.utc(2026, 3, 8, 10)
    create_visit(deal: deal, stage: new_stage, entered_at: entered_at - 1.hour, exited_at: entered_at)
    create_visit(
      deal: deal,
      stage: qualified_stage,
      entered_at: entered_at,
      reliable_since: entered_at + 1.hour
    )

    expect(query.drill_down_rows.fetch(0)).to include(reliability: 'exact', coverage: 'unknown_before')
    expect(query.aggregate_rows.fetch(0)).to include(
      total_count: 1,
      exact_count: 1,
      estimated_count: 0,
      coverage: 'unknown_before'
    )
  end

  it 'uses a half-open workspace-local DST window and destination filters' do
    inside = Time.utc(2026, 3, 9, 3, 59, 59)
    outside = Time.utc(2026, 3, 9, 4)
    first_deal = deal
    second_deal = create(:crm_deal, account: account, pipeline: pipeline, stage: won_stage)

    create_visit(deal: first_deal, stage: new_stage, entered_at: inside - 1.hour, exited_at: inside)
    included = create_visit(deal: first_deal, stage: won_stage, entered_at: inside)
    create_visit(deal: second_deal, stage: new_stage, entered_at: outside - 1.hour, exited_at: outside)
    create_visit(deal: second_deal, stage: won_stage, entered_at: outside)

    filtered = described_class.new(
      account: account,
      deals_scope: account.crm_deals,
      params: base_params.merge(pipeline_id: pipeline.id, stage_id: won_stage.id)
    )

    expect(filtered.drill_down_rows.pluck(:transition_visit_id)).to eq([included.id])
    expect(filtered.meta).to include(
      timezone: 'America/New_York',
      from: '2026-03-08T05:00:00.000000Z',
      to: '2026-03-09T04:00:00.000000Z'
    )
  end

  it 'uses one scoped relation for aggregate, pagination, archived deals, and count parity' do
    visible_deal = deal
    archived_deal = create(:crm_deal, account: account, pipeline: pipeline, stage: won_stage, archived_at: Time.current)
    hidden_deal = create(:crm_deal, account: account, pipeline: pipeline, stage: won_stage)
    timestamp = Time.utc(2026, 3, 8, 12)

    [visible_deal, archived_deal, hidden_deal].each do |record|
      create_visit(deal: record, stage: new_stage, entered_at: timestamp - 1.hour, exited_at: timestamp)
      create_visit(deal: record, stage: won_stage, entered_at: timestamp)
    end

    scoped_query = described_class.new(
      account: account,
      deals_scope: account.crm_deals.where(id: [visible_deal.id, archived_deal.id]),
      params: base_params.merge(page: 2, per_page: 1)
    )

    expect(scoped_query.aggregate_rows.sum { |row| row[:total_count] }).to eq(2)
    expect(scoped_query.pagination_meta).to include(page: 2, per_page: 1, total_count: 2)
    expect(scoped_query.drill_down_rows.pluck(:deal_id)).to contain_exactly(visible_deal.id)
  end

  it 'rejects invalid, oversized, paginated, and foreign-account filters deterministically' do
    foreign_stage = create(:crm_stage)

    expectations = [
      [{ from_date: '2026-02-30', to_date: '2026-03-01' }, 'from_date must be a valid date'],
      [{ from_date: '2025-01-01', to_date: '2026-03-01' }, 'date window must not exceed 366 days'],
      [base_params.merge(per_page: 101), 'per_page must not exceed 100'],
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
