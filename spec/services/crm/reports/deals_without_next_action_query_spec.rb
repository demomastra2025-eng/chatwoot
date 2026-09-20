require 'rails_helper'

RSpec.describe Crm::Reports::DealsWithoutNextActionQuery do
  let(:account) { create(:account, settings: { 'workspace_timezone' => 'America/New_York' }) }
  let(:pipeline) { create(:crm_pipeline, account: account) }
  let(:stage) { create(:crm_stage, account: account, pipeline: pipeline) }
  let(:open_status) { create(:crm_task_status, account: account, category: 'open') }
  let(:done_status) { create(:crm_task_status, account: account, category: 'done') }
  let(:generated_at) { Time.utc(2026, 3, 8, 7, 30) }

  def build_query(params = {})
    described_class.new(
      account: account,
      deals_scope: account.crm_deals,
      tasks_scope: account.crm_tasks,
      params: params,
      generated_at: generated_at
    )
  end

  it 'uses one set-based anti-join for waiting and all open task schedule variants' do
    no_action = create(:crm_deal, account: account, pipeline: pipeline, stage: stage)
    foreign_deal = create(:crm_deal, account: create(:account))
    create(:crm_deal, account: account, pipeline: pipeline, stage: stage, waiting_until: 1.day.ago,
                      waiting_started_at: 2.days.ago, waiting_reason: 'Customer')
    timed = create(:crm_deal, account: account, pipeline: pipeline, stage: stage)
    all_day = create(:crm_deal, account: account, pipeline: pipeline, stage: stage)
    unscheduled = create(:crm_deal, account: account, pipeline: pipeline, stage: stage)
    create(:crm_task, account: account, deal: timed, status: open_status, due_at: generated_at + 1.hour)
    create(:crm_task, account: account, deal: all_day, status: open_status, all_day: true, due_on: Date.new(2026, 3, 8))
    create(:crm_task, account: account, deal: unscheduled, status: open_status, due_at: nil, due_on: nil)

    query = described_class.new(
      account: account,
      deals_scope: Crm::Deal.all,
      tasks_scope: Crm::Task.all,
      generated_at: generated_at
    )

    expect(query.relation).to contain_exactly(no_action)
    expect(query.relation).not_to include(foreign_deal)
    expect(query.relation.to_sql).to include('NOT EXISTS', 'crm_tasks.deal_id = crm_deals.id')
    expect(query.meta).to include(
      metric_kind: 'current_snapshot',
      reliability: 'exact',
      generated_at: '2026-03-08T07:30:00.000000Z',
      generated_at_local: '2026-03-08T03:30:00.000000-04:00',
      timezone: 'America/New_York'
    )
    expect(query.drill_down_rows.first.keys).not_to include(:task_id, :task)
  end

  it 'uses one materialized SQL snapshot for detail rows and their total count' do
    create(:crm_deal, account: account, pipeline: pipeline, stage: stage)
    sql = []
    subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |event|
      sql << event.payload[:sql] if event.payload[:sql].include?('matching_deals AS MATERIALIZED')
    end

    query = build_query
    expect(query.pagination_meta[:total_count]).to eq(1)
    expect(query.drill_down_rows.size).to eq(1)
    expect(sql.one?).to be(true)

    empty_page = build_query(page: 2, per_page: 1)
    expect(empty_page.drill_down_rows).to be_empty
    expect(empty_page.pagination_meta[:total_count]).to eq(1)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  it 'keeps the detail snapshot narrow, tenant-scoped, and anchored before execution' do
    captured_at = Time.utc(2026, 5, 1, 10)
    safe_deal = create(:crm_deal, account: account, pipeline: pipeline, stage: stage)
    corrupt_catalog_deal = create(:crm_deal, account: account, pipeline: pipeline, stage: stage)
    foreign_account = create(:account)
    foreign_owner = create(:user, account: foreign_account)
    foreign_team = create(:team, account: foreign_account)
    foreign_pipeline = create(:crm_pipeline, account: foreign_account)
    foreign_stage = create(:crm_stage, account: foreign_account, pipeline: foreign_pipeline)
    safe_deal.update_columns(owner_id: foreign_owner.id, team_id: foreign_team.id) # rubocop:disable Rails/SkipsModelValidations
    corrupt_catalog_deal.update_columns( # rubocop:disable Rails/SkipsModelValidations
      pipeline_id: foreign_pipeline.id, stage_id: foreign_stage.id
    )
    query = travel_to(captured_at) do
      described_class.new(account: account, deals_scope: account.crm_deals, tasks_scope: account.crm_tasks)
    end
    sql = query.send(:details_sql)

    expect(sql).not_to include('crm_deals.*', 'description', 'custom_attributes', 'closing_reasons')
    expect(sql.scan("account_id = #{account.id}").size).to be >= 4
    expect(query.drill_down_rows).to contain_exactly(include(deal_id: safe_deal.id, owner: nil, team: nil))
    expect(query.pagination_meta[:total_count]).to eq(1)
    expect(query.aggregate_rows).to eq([{ no_action_count: 1 }])
    travel_to(captured_at + 1.hour) do
      expect(query.meta[:generated_at]).to eq('2026-05-01T10:00:00.000000Z')
    end
  end

  it 'excludes archived and closed deals while ignoring archived and terminal tasks' do
    visible = create(:crm_deal, account: account, pipeline: pipeline, stage: stage)
    archived = create(:crm_deal, account: account, pipeline: pipeline, stage: stage, archived_at: generated_at)
    closed = create(:crm_deal, account: account, pipeline: pipeline, stage: stage, closed_at: generated_at)
    create(:crm_task, account: account, deal: visible, status: open_status, archived_at: generated_at)
    create(:crm_task, account: account, deal: visible, status: done_status)

    expect(build_query.relation).to contain_exactly(visible)
    expect(build_query.relation).not_to include(archived, closed)
  end

  it 'validates tenant-owned filters and bounded pagination' do
    owner = create(:user, account: account)
    team = create(:team, account: account)
    matching = create(:crm_deal, account: account, pipeline: pipeline, stage: stage, owner: owner, team: team)
    create(:crm_deal, account: account, owner: owner, team: team)
    params = { pipeline_id: pipeline.id, stage_id: stage.id, owner_id: owner.id, team_id: team.id, page: 1, per_page: 1 }

    query = build_query(params)

    expect(query.drill_down_rows.pluck(:deal_id)).to eq([matching.id])
    expect(query.pagination_meta).to include(page: 1, per_page: 1, total_count: 1)

    foreign_pipeline = create(:crm_pipeline, account: create(:account))
    expect { build_query(pipeline_id: foreign_pipeline.id) }
      .to raise_error(Crm::Error, 'pipeline_id is invalid')
    expect { build_query(per_page: 101).pagination_meta }
      .to raise_error(Crm::Error, 'per_page must not exceed 100')
    expect { build_query(page: 10_001).pagination_meta }
      .to raise_error(Crm::Error, 'page must not exceed 10000')
  end
end
