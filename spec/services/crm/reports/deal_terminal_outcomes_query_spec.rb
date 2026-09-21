require 'rails_helper'

RSpec.describe Crm::Reports::DealTerminalOutcomesQuery do
  let(:account) { create(:account, settings: { 'workspace_timezone' => 'America/New_York' }) }
  let(:pipeline) { create(:crm_pipeline, account: account, name: 'Sales') }
  let(:won_stage) { create(:crm_stage, account: account, pipeline: pipeline, name: 'Won', outcome: 'won') }
  let(:lost_stage) { create(:crm_stage, account: account, pipeline: pipeline, name: 'Lost', outcome: 'lost') }
  let(:base_params) { { from_date: '2026-03-08', to_date: '2026-03-08', as_of_date: '2026-03-09' } }

  def build_query(params = {}, scope: account.crm_deals)
    described_class.new(account: account, deals_scope: scope, params: base_params.merge(params))
  end

  def terminal_visit(deal:, stage:, at:, **attributes)
    owner = attributes.delete(:owner)
    team = attributes.delete(:team)
    version = attributes.delete(:version) { 1 }
    create(
      :crm_stage_visit,
      account: account,
      deal: deal,
      pipeline: pipeline,
      stage: stage,
      pipeline_name: pipeline.name,
      stage_name: stage.name,
      stage_outcome: stage.outcome,
      entered_at: at,
      reliable_since: at,
      owner_id_at_terminal: owner&.id,
      team_id_at_terminal: team&.id,
      terminal_attribution_version: version,
      **attributes
    )
  end

  it 'projects immutable close attribution across reassignment, reopen/reclose, and won-to-lost occurrences' do
    first_owner = create(:user, account: account, name: 'First owner')
    second_owner = create(:user, account: account, name: 'Second owner')
    first_team = create(:team, account: account, name: 'First team')
    second_team = create(:team, account: account, name: 'Second team')
    deal = create(:crm_deal, account: account, pipeline: pipeline, stage: lost_stage, owner: second_owner, team: second_team)
    won = terminal_visit(
      deal: deal, stage: won_stage, at: Time.utc(2026, 3, 8, 12), owner: first_owner, team: first_team,
      exited_at: Time.utc(2026, 3, 8, 13)
    )
    lost = terminal_visit(deal: deal, stage: lost_stage, at: Time.utc(2026, 3, 8, 14), owner: second_owner, team: second_team)

    query = build_query
    details = query.drill_down_rows
    owner_rows = query.aggregate_rows.select { |row| row[:dimension] == 'owner' }

    expect(details.pluck(:stage_visit_id)).to eq([lost.id, won.id])
    expect(details.map { |row| [row[:outcome], row.dig(:owner, :id)] }).to eq([['lost', second_owner.id], ['won', first_owner.id]])
    expect(owner_rows).to contain_exactly(
      include(outcome: 'won', attribution: include(id: first_owner.id), outcome_count: 1, reliability: 'exact'),
      include(outcome: 'lost', attribution: include(id: second_owner.id), outcome_count: 1, reliability: 'exact')
    )
    expect(query.meta).to include(total_count: 2, exact_count: 2, unknown_count: 0, coverage: 'exact_rows_only')
  end

  it 'distinguishes known unassigned v1 from marker-less legacy or overlap unknown' do
    known_deal = create(:crm_deal, account: account, pipeline: pipeline, stage: won_stage)
    legacy_deal = create(:crm_deal, account: account, pipeline: pipeline, stage: lost_stage)
    terminal_visit(deal: known_deal, stage: won_stage, at: Time.utc(2026, 3, 8, 12))
    terminal_visit(deal: legacy_deal, stage: lost_stage, at: Time.utc(2026, 3, 8, 13), version: nil)

    query = build_query
    details = query.drill_down_rows.index_by { |row| row[:outcome] }
    owner_rows = query.aggregate_rows.select { |row| row[:dimension] == 'owner' }

    expect(details.fetch('won')).to include(owner: include(id: nil, state: 'not_configured'), reliability: 'exact')
    expect(details.fetch('lost')).to include(owner: include(id: nil, state: 'unknown'), reliability: 'unknown')
    expect(owner_rows).to contain_exactly(
      include(outcome: 'won', attribution: include(state: 'not_configured'), outcome_count: 1),
      include(outcome: 'lost', attribution: include(state: 'unknown'), outcome_count: 1)
    )
    expect(query.meta).to include(total_count: 2, exact_count: 1, unknown_count: 1, coverage: 'mixed',
                                  global_reliability: 'unknown_until_cutover_recorded')
  end

  it 'keeps deleted identities as known historical ids without borrowing foreign catalog labels' do
    owner = create(:user, account: account, name: 'Former owner')
    team = create(:team, account: account, name: 'Former team')
    deal = create(:crm_deal, account: account, pipeline: pipeline, stage: won_stage)
    visit = terminal_visit(deal: deal, stage: won_stage, at: Time.utc(2026, 3, 8, 12), owner: owner, team: team)
    raw_owner_id = owner.id
    raw_team_id = team.id
    deal.update_columns(owner_id: nil, team_id: nil) # rubocop:disable Rails/SkipsModelValidations
    account.account_users.find_by!(user: owner).destroy!
    team.destroy!

    row = build_query.drill_down_rows.sole

    expect(row).to include(stage_visit_id: visit.id)
    expect(row[:owner]).to eq(id: raw_owner_id, name: nil, state: 'historical_identity')
    expect(row[:team]).to eq(id: raw_team_id, name: nil, state: 'historical_identity')
  end

  it 'uses a Workspace-local half-open DST window and an explicit observation cutoff' do
    inside_deal = create(:crm_deal, account: account, pipeline: pipeline, stage: won_stage)
    outside_deal = create(:crm_deal, account: account, pipeline: pipeline, stage: won_stage)
    inside = terminal_visit(deal: inside_deal, stage: won_stage, at: Time.utc(2026, 3, 9, 3, 59, 59))
    terminal_visit(deal: outside_deal, stage: won_stage, at: Time.utc(2026, 3, 9, 4))

    query = build_query

    expect(query.drill_down_rows.pluck(:stage_visit_id)).to eq([inside.id])
    expect(query.meta).to include(
      from: '2026-03-08T05:00:00.000000Z',
      to: '2026-03-09T04:00:00.000000Z',
      as_of: '2026-03-10T04:00:00.000000Z',
      timezone: 'America/New_York'
    )
  end

  it 'shares filters, totals, reliability, fingerprint, and bounded stable pagination' do
    owner = create(:user, account: account)
    first_deal = create(:crm_deal, account: account, pipeline: pipeline, stage: won_stage)
    second_deal = create(:crm_deal, account: account, pipeline: pipeline, stage: won_stage)
    first = terminal_visit(deal: first_deal, stage: won_stage, at: Time.utc(2026, 3, 8, 12), owner: owner,
                           exited_at: Time.utc(2026, 3, 8, 13))
    second = terminal_visit(deal: second_deal, stage: won_stage, at: Time.utc(2026, 3, 8, 13), owner: owner)
    filters = { dimension: 'owner', owner_id: owner.id, outcome: 'won' }
    aggregate = build_query(filters)
    details = build_query(filters.merge(page: 2, per_page: 1))

    expect(aggregate.aggregate_rows).to contain_exactly(include(outcome_count: 2, attribution: include(id: owner.id)))
    expect(details.drill_down_rows.pluck(:stage_visit_id)).to eq([first.id])
    expect(details.pagination_meta).to include(page: 2, per_page: 1, total_count: 2, exact_count: 2, unknown_count: 0)
    expect(details.pagination_meta[:query_fingerprint]).to eq(aggregate.meta[:query_fingerprint])
    expect(details.drill_down_rows.pluck(:stage_visit_id)).not_to include(second.id)
    expect { build_query(filters.merge(per_page: 101)).pagination_meta }.to raise_error(Crm::Error, 'per_page must not exceed 100')
    expect { build_query(filters.merge(page: 10_001)).pagination_meta }.to raise_error(Crm::Error, 'page must not exceed 10000')
  end

  it 'uses only the policy-scoped account cohort and tenant-safe current labels' do
    visible = create(:crm_deal, account: account, pipeline: pipeline, stage: won_stage)
    hidden = create(:crm_deal, account: account, pipeline: pipeline, stage: won_stage)
    corrupt = create(:crm_deal, account: account, pipeline: pipeline, stage: won_stage)
    foreign_account = create(:account)
    foreign_deal = create(:crm_deal, account: foreign_account)
    foreign_stage = create(:crm_stage, account: foreign_account, pipeline: foreign_deal.pipeline, outcome: 'won')
    visible_visit = terminal_visit(deal: visible, stage: won_stage, at: Time.utc(2026, 3, 8, 12))
    terminal_visit(deal: hidden, stage: won_stage, at: Time.utc(2026, 3, 8, 13))
    corrupt_visit = terminal_visit(deal: corrupt, stage: won_stage, at: Time.utc(2026, 3, 8, 13, 30))
    corrupt_visit.update_column(:account_id, foreign_account.id) # rubocop:disable Rails/SkipsModelValidations
    create(:crm_stage_visit, account: foreign_account, deal: foreign_deal, pipeline: foreign_deal.pipeline, stage: foreign_stage,
                             stage_outcome: 'won', entered_at: Time.utc(2026, 3, 8, 14), reliable_since: Time.utc(2026, 3, 8, 14),
                             terminal_attribution_version: 1)

    query = build_query(scope: account.crm_deals.where(id: [visible.id, corrupt.id]))

    expect(query.drill_down_rows.pluck(:stage_visit_id)).to eq([visible_visit.id])
    expect(query.meta[:total_count]).to eq(1)
  end

  it 'rejects hidden attribution filters and invalid temporal or dimensional inputs' do
    hidden_owner = create(:user, account: account)
    hidden_deal = create(:crm_deal, account: account, pipeline: pipeline, stage: won_stage)
    terminal_visit(deal: hidden_deal, stage: won_stage, at: Time.utc(2026, 3, 8, 12), owner: hidden_owner)
    empty_scope = account.crm_deals.none

    expect { build_query({ dimension: 'owner', owner_id: hidden_owner.id }, scope: empty_scope) }
      .to raise_error(Crm::Error, 'owner_id is invalid')
    expect { build_query({ dimension: 'manager' }) }.to raise_error(Crm::Error, 'dimension must be owner or team')
    expect { build_query({ owner_id: hidden_owner.id }) }.to raise_error(Crm::Error, 'dimension=owner is required with owner_id')
    expect { build_query({ as_of_date: '2026-03-07' }) }.to raise_error(Crm::Error, 'as_of_date must be on or after to_date')
    expect { described_class.new(account: account, deals_scope: account.crm_deals, params: {}) }
      .to raise_error(Crm::Error, 'from_date is required')
  end
end
