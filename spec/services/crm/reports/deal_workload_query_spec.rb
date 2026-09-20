require 'rails_helper'

RSpec.describe Crm::Reports::DealWorkloadQuery do
  let(:account) { create(:account, settings: { 'workspace_timezone' => 'America/New_York' }) }
  let(:pipeline) { create(:crm_pipeline, account: account) }
  let(:stage) { create(:crm_stage, account: account, pipeline: pipeline) }
  let(:generated_at) { Time.utc(2026, 3, 8, 7, 30) }

  def build_query(params = {}, scope: account.crm_deals)
    described_class.new(
      account: account,
      deals_scope: scope,
      params: params,
      generated_at: generated_at
    )
  end

  it 'returns independent owner and Team dimensions with mutually exclusive current states' do
    owner = create(:user, account: account, name: 'Owner A')
    team = create(:team, account: account, name: 'Team A')
    create(:team_member, team: team, user: owner)
    create(:crm_deal, account: account, pipeline: pipeline, stage: stage, owner: owner, team: team)
    create(:crm_deal, account: account, pipeline: pipeline, stage: stage, owner: owner,
                      waiting_until: 1.hour.ago, waiting_started_at: 1.day.ago, waiting_reason: 'Expired')
    create(:crm_deal, account: account, pipeline: pipeline, stage: stage, team: team)

    rows = build_query.aggregate_rows.index_by { |row| [row[:dimension], row.dig(:attribution, :id)] }

    expect(rows.fetch(['owner', owner.id])).to include(open_count: 2, waiting_count: 1, actionable_count: 1)
    expect(rows.fetch(['owner', nil])).to include(open_count: 1, waiting_count: 0, actionable_count: 1)
    expect(rows.fetch(['team', team.id])).to include(open_count: 2, waiting_count: 0, actionable_count: 2)
    expect(rows.fetch(['team', nil])).to include(open_count: 1, waiting_count: 1, actionable_count: 0)
    expect(rows.fetch(['owner', nil])[:attribution]).to include(state: 'not_configured')
    expect(rows.fetch(['team', nil])[:attribution]).to include(state: 'not_configured')
    expect(rows.values).to all(satisfy { |row| row[:open_count] == row[:waiting_count] + row[:actionable_count] })
  end

  it 'keeps persisted Team attribution despite current membership drift' do
    owner = create(:user, account: account)
    persisted_team = create(:team, account: account)
    current_team = create(:team, account: account)
    create(:team_member, team: current_team, user: owner)
    create(:crm_deal, account: account, pipeline: pipeline, stage: stage, owner: owner, team: persisted_team)

    team_rows = build_query({ dimension: 'team' }).aggregate_rows

    expect(team_rows.one?).to be(true)
    expect(team_rows.first[:attribution]).to include(id: persisted_team.id, state: 'current_catalog_projection')
  end

  it 'uses tenant-safe catalogs and excludes corrupt pipeline or stage dimensions' do
    foreign_account = create(:account)
    foreign_owner = create(:user, account: foreign_account, name: 'Foreign owner')
    foreign_team = create(:team, account: foreign_account, name: 'Foreign team')
    visible = create(:crm_deal, account: account, pipeline: pipeline, stage: stage)
    visible.update_columns(owner_id: foreign_owner.id, team_id: foreign_team.id) # rubocop:disable Rails/SkipsModelValidations
    corrupt = create(:crm_deal, account: account, pipeline: pipeline, stage: stage)
    foreign_pipeline = create(:crm_pipeline, account: foreign_account)
    foreign_stage = create(:crm_stage, account: foreign_account, pipeline: foreign_pipeline)
    corrupt.update_columns(pipeline_id: foreign_pipeline.id, stage_id: foreign_stage.id) # rubocop:disable Rails/SkipsModelValidations

    query = build_query
    details = query.drill_down_rows

    expect(details.pluck(:deal_id)).to eq([visible.id])
    expect(details.first).to include(owner: include(id: foreign_owner.id, name: nil, state: 'unknown'))
    expect(details.first).to include(team: include(id: foreign_team.id, name: nil, state: 'unknown'))
    expect(query.meta[:total_count]).to eq(1)
    expect(details.to_json).not_to include('Foreign owner', 'Foreign team')
  end

  it 'shares normalized filters and a materialized snapshot across aggregate and details' do
    owner = create(:user, account: account)
    matching = create(:crm_deal, account: account, pipeline: pipeline, stage: stage, owner: owner)
    create(:crm_deal, account: account, pipeline: pipeline, stage: stage)
    sql = []
    subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |event|
      sql << event.payload[:sql] if event.payload[:sql].include?('matching_deals AS MATERIALIZED')
    end
    filters = { dimension: 'owner', owner_id: owner.id, pipeline_id: pipeline.id, stage_id: stage.id }
    aggregate = build_query(filters)
    details = build_query(filters.merge(page: 1, per_page: 1))

    expect(aggregate.aggregate_rows).to contain_exactly(include(dimension: 'owner', open_count: 1))
    expect(details.drill_down_rows.pluck(:deal_id)).to eq([matching.id])
    expect(details.pagination_meta[:total_count]).to eq(1)
    expect(aggregate.meta[:query_fingerprint]).to eq(details.pagination_meta[:query_fingerprint])
    expect(sql.size).to eq(2)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  it 'supports an explicit unassigned bucket and stable bounded pagination' do
    first = create(:crm_deal, account: account, pipeline: pipeline, stage: stage)
    second = create(:crm_deal, account: account, pipeline: pipeline, stage: stage)
    create(:crm_deal, account: account, pipeline: pipeline, stage: stage, owner: create(:user, account: account))

    query = build_query({ dimension: 'owner', owner_id: 'unassigned', page: 2, per_page: 1 })

    expect(query.aggregate_rows).to contain_exactly(include(open_count: 2, attribution: include(id: nil, state: 'not_configured')))
    expect(query.drill_down_rows.pluck(:deal_id)).to eq([second.id])
    expect(query.pagination_meta).to include(page: 2, per_page: 1, total_count: 2)
    expect(query.drill_down_rows.pluck(:deal_id)).not_to include(first.id)
  end

  it 'excludes closed and archived Deals and returns an exact empty zero' do
    create(:crm_deal, account: account, pipeline: pipeline, stage: stage, closed_at: generated_at)
    create(:crm_deal, account: account, pipeline: pipeline, stage: stage, archived_at: generated_at)

    query = build_query

    expect(query.aggregate_rows).to be_empty
    expect(query.meta).to include(total_count: 0, reliability: 'exact', historical_attribution: 'unknown_not_supported')
    expect(query.drill_down_rows).to be_empty
    expect(query.pagination_meta[:total_count]).to eq(0)
  end

  it 'rejects historical, incoherent, foreign, and unbounded inputs' do
    foreign_owner = create(:user, account: create(:account))

    expect { build_query({ as_of: generated_at }) }.to raise_error(Crm::Error, 'as_of is not supported for current snapshots')
    expect { build_query({ dimension: 'manager' }) }.to raise_error(Crm::Error, 'dimension must be owner or team')
    expect { build_query({ owner_id: 1 }) }.to raise_error(Crm::Error, 'dimension=owner is required with owner_id')
    expect { build_query({ dimension: 'owner', owner_id: foreign_owner.id }) }.to raise_error(Crm::Error, 'owner_id is invalid')
    expect { build_query({ dimension: 'owner', team_id: 'unassigned' }) }
      .to raise_error(Crm::Error, 'dimension=team is required with team_id')
    expect { build_query({ page: 10_001 }).pagination_meta }.to raise_error(Crm::Error, 'page must not exceed 10000')
    expect { build_query({ per_page: 101 }).pagination_meta }.to raise_error(Crm::Error, 'per_page must not exceed 100')
  end
end
