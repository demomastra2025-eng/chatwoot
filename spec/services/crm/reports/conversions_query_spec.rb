require 'rails_helper'

RSpec.describe Crm::Reports::ConversionsQuery do
  let(:account) { create(:account, settings: { 'workspace_timezone' => 'America/New_York' }) }
  let(:pipeline) { create(:crm_pipeline, account: account, name: 'Sales', code: 'sales') }
  let(:new_stage) { create(:crm_stage, account: account, pipeline: pipeline, name: 'New', code: 'new') }
  let(:won_stage) { create(:crm_stage, account: account, pipeline: pipeline, name: 'Won', code: 'won', outcome: 'won') }
  let(:lost_stage) { create(:crm_stage, account: account, pipeline: pipeline, name: 'Lost', code: 'lost', outcome: 'lost') }
  let(:base_params) { { from_date: '2026-03-08', to_date: '2026-03-08', as_of_date: '2026-03-10' } }
  let(:query) { described_class.new(account: account, deals_scope: account.crm_deals, params: base_params) }

  def create_visit(deal:, stage:, entered_at:, **attributes)
    deal.stage_visits.active.order(:entered_at, :id).last&.update!(exited_at: entered_at)
    create(
      :crm_stage_visit,
      account: deal.account,
      deal: deal,
      pipeline: stage.pipeline,
      stage: stage,
      entered_at: entered_at,
      reliable_since: attributes.delete(:reliable_since) || entered_at,
      **attributes
    )
  end

  def create_stage_event(deal:, visit:, reasons:)
    create(
      :crm_event,
      account: deal.account,
      eventable: deal,
      event_type: 'deal_stage_changed',
      correlation_id: visit.correlation_id,
      after_data: {
        stage_id: visit.stage_id,
        pipeline_id: visit.pipeline_id,
        closing_reasons: reasons
      }
    )
  end

  it 'defines the cohort by first visit and uses the first terminal outcome by as-of' do
    deal = create(:crm_deal, account: account, pipeline: pipeline, stage: won_stage)
    cohort = create_visit(deal: deal, stage: new_stage, entered_at: Time.utc(2026, 3, 8, 12))
    lost = create_visit(deal: deal, stage: lost_stage, entered_at: Time.utc(2026, 3, 9, 12))
    create_stage_event(deal: deal, visit: lost, reasons: %w[Budget Timing])
    create_visit(deal: deal, stage: won_stage, entered_at: Time.utc(2026, 3, 10, 12))

    row = query.drill_down_rows.fetch(0)
    aggregate = query.aggregate_rows.fetch(0)

    expect(row).to include(
      cohort_visit_id: cohort.id,
      deal_id: deal.id,
      outcome: 'lost',
      closing_reasons: %w[Budget Timing],
      closing_reasons_reliability: 'exact',
      reliability: 'exact'
    )
    expect(row.dig(:terminal, :stage_visit_id)).to eq(lost.id)
    expect(aggregate).to include(
      cohort_count: 1,
      won_count: 0,
      lost_count: 1,
      unconverted_count: 0,
      conversion_rate_percent: 0.0,
      loss_reasons: [{ reason: 'Budget', deal_count: 1 }, { reason: 'Timing', deal_count: 1 }]
    )
  end

  it 'uses half-open workspace-local cohort and as-of bounds across DST' do
    inside = create(:crm_deal, account: account, pipeline: pipeline, stage: won_stage)
    terminal_outside = create(:crm_deal, account: account, pipeline: pipeline, stage: won_stage)
    cohort = create_visit(deal: inside, stage: new_stage, entered_at: Time.utc(2026, 3, 9, 3, 59, 59))
    create_visit(deal: inside, stage: won_stage, entered_at: Time.utc(2026, 3, 10, 3, 59, 59))
    create_visit(deal: terminal_outside, stage: new_stage, entered_at: Time.utc(2026, 3, 8, 12))
    create_visit(deal: terminal_outside, stage: won_stage, entered_at: Time.utc(2026, 3, 11, 4))
    outside_cohort = create(:crm_deal, account: account, pipeline: pipeline, stage: new_stage)
    create_visit(deal: outside_cohort, stage: new_stage, entered_at: Time.utc(2026, 3, 9, 4))

    rows = query.drill_down_rows

    expect(rows.pluck(:cohort_visit_id)).to include(cohort.id)
    expect(rows.pluck(:deal_id)).not_to include(outside_cohort.id)
    expect(rows.find { |row| row[:deal_id] == terminal_outside.id }).to include(outcome: 'unconverted', terminal: nil)
    expect(query.meta).to include(
      from: '2026-03-08T05:00:00.000000Z',
      to: '2026-03-09T04:00:00.000000Z',
      as_of: '2026-03-11T04:00:00.000000Z',
      cohort_definition: 'first_stage_visit_entered_in_window'
    )
  end

  it 'separates exact, estimated, and unknown facts without fabricating a rate' do
    entered_at = Time.utc(2026, 3, 8, 12)
    exact = create(:crm_deal, account: account, pipeline: pipeline, stage: won_stage)
    estimated = create(:crm_deal, account: account, pipeline: pipeline, stage: lost_stage)
    unknown = create(:crm_deal, account: account, pipeline: pipeline, stage: new_stage)
    create_visit(deal: exact, stage: won_stage, entered_at: entered_at)
    create_visit(deal: estimated, stage: lost_stage, entered_at: entered_at, estimated: true)
    create_visit(deal: unknown, stage: new_stage, entered_at: entered_at, reliable_since: entered_at + 1.hour)

    rows = query.drill_down_rows
    aggregate = query.aggregate_rows.fetch(0)

    expect(rows.pluck(:reliability)).to contain_exactly('exact', 'estimated', 'unknown')
    expect(aggregate).to include(
      exact_count: 1,
      estimated_count: 1,
      unknown_count: 1,
      conversion_rate_percent: nil,
      coverage: 'unknown'
    )
    expect(query.meta).to include(coverage: 'unknown')
  end

  it 'distinguishes unknown and known-empty loss reasons' do
    timestamp = Time.utc(2026, 3, 8, 12)
    unknown = create(:crm_deal, account: account, pipeline: pipeline, stage: lost_stage)
    known_empty = create(:crm_deal, account: account, pipeline: pipeline, stage: lost_stage)
    create_visit(deal: unknown, stage: lost_stage, entered_at: timestamp)
    known_visit = create_visit(deal: known_empty, stage: lost_stage, entered_at: timestamp)
    create_stage_event(deal: known_empty, visit: known_visit, reasons: [])

    aggregate = query.aggregate_rows.fetch(0)
    rows = query.drill_down_rows.index_by { |row| row[:deal_id] }

    expect(aggregate).to include(unknown_loss_reason_count: 1, not_configured_loss_reason_count: 1)
    expect(rows.fetch(unknown.id)).to include(closing_reasons: nil, closing_reasons_reliability: 'unknown')
    expect(rows.fetch(known_empty.id)).to include(closing_reasons: [], closing_reasons_reliability: 'exact')
  end

  it 'shares one scoped fact relation across aggregate, pagination, archived deals, filters, and parity' do
    timestamp = Time.utc(2026, 3, 8, 12)
    visible = create(:crm_deal, account: account, pipeline: pipeline, stage: lost_stage)
    archived = create(:crm_deal, account: account, pipeline: pipeline, stage: lost_stage, archived_at: Time.current)
    hidden = create(:crm_deal, account: account, pipeline: pipeline, stage: lost_stage)
    [visible, archived, hidden].each do |deal|
      visit = create_visit(deal: deal, stage: lost_stage, entered_at: timestamp)
      create_stage_event(deal: deal, visit: visit, reasons: ['Budget'])
    end

    scoped_query = described_class.new(
      account: account,
      deals_scope: account.crm_deals.where(id: [visible.id, archived.id]),
      params: base_params.merge(outcome: 'lost', closing_reason: 'Budget', page: 2, per_page: 1)
    )

    expect(scoped_query.aggregate_rows.sum { |row| row[:cohort_count] }).to eq(2)
    expect(scoped_query.pagination_meta).to include(page: 2, per_page: 1, total_count: 2)
    expect(scoped_query.drill_down_rows.pluck(:deal_id)).to contain_exactly(visible.id)
  end

  it 'rejects invalid observation, pagination, account filters, and reason combinations' do
    foreign_pipeline = create(:crm_pipeline)
    expectations = [
      [base_params.except(:as_of_date), 'as_of_date is required'],
      [base_params.merge(as_of_date: '2026-03-07'), 'as_of_date must be on or after to_date'],
      [base_params.merge(per_page: 101), 'per_page must not exceed 100'],
      [base_params.merge(pipeline_id: foreign_pipeline.id), 'pipeline filter is invalid'],
      [base_params.merge(outcome: 'open'), 'outcome is invalid'],
      [base_params.merge(closing_reason: 'Budget'), 'closing_reason requires outcome=lost']
    ]

    expectations.each do |params, message|
      expect do
        report = described_class.new(account: account, deals_scope: account.crm_deals, params: params)
        report.pagination_meta if params[:per_page]
      end.to raise_error(Crm::Error, message)
    end
  end
end
