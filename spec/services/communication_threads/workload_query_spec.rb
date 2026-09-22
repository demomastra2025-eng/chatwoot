require 'rails_helper'

RSpec.describe CommunicationThreads::WorkloadQuery do
  let(:account) { create(:account, settings: { 'workspace_timezone' => 'Asia/Almaty' }) }
  let(:generated_at) { Time.utc(2026, 9, 22, 6, 0) }

  def build_query(params = {}, scope: CommunicationThread.where(account_id: account.id))
    described_class.new(account: account, threads_scope: scope, params: params, generated_at: generated_at)
  end

  it 'reports independent owner and Team dimensions from current unresolved rows' do
    owner = create(:user, account: account, name: 'Owner')
    team = create(:team, account: account, name: 'Queue')
    multi_channel_thread = create(:communication_thread, account: account, assignee: owner, team: team, status: :open, priority: :high,
                                                         unread_count: 3, last_activity_at: generated_at - 1.hour)
    create_list(:communication_thread_conversation, 2, account: account, communication_thread: multi_channel_thread)
    create(:communication_thread, account: account, assignee: owner, status: :pending, priority: nil,
                                  unread_count: 0, last_activity_at: nil)
    create(:communication_thread, account: account, team: team, status: :snoozed, priority: :urgent,
                                  unread_count: 2, last_activity_at: generated_at - 2.hours)
    create(:communication_thread, account: account, assignee: owner, team: team, status: :resolved,
                                  unread_count: 99)
    create(:communication_thread, account: create(:account), status: :open, unread_count: 99)

    rows = build_query.aggregate_rows.index_by { |row| [row[:dimension], row.dig(:attribution, :id)] }

    expect(rows.fetch(['owner', owner.id])).to include(
      unresolved_count: 2, open_count: 1, pending_count: 1, snoozed_count: 0,
      priority_high_count: 1, priority_not_configured_count: 1,
      unread_threads_count: 1, unread_count: 3, last_activity_unknown_count: 1
    )
    expect(rows.fetch(['owner', nil])).to include(unresolved_count: 1, snoozed_count: 1, unread_count: 2)
    expect(rows.fetch(['team', team.id])).to include(unresolved_count: 2, open_count: 1, snoozed_count: 1, unread_count: 5)
    expect(rows.fetch(['team', nil])).to include(unresolved_count: 1, pending_count: 1)
    expect(rows.values).to all(satisfy do |row|
      row[:unresolved_count] == row[:open_count] + row[:pending_count] + row[:snoozed_count]
    end)
    expect(build_query.meta).to include(total_count: 3, metric_kind: 'current_snapshot', historical_attribution: 'unknown_not_supported')
  end

  it 'keeps rows when current owner or Team labels are unavailable without leaking foreign labels' do
    former_owner = create(:user, account: account, name: 'Former owner')
    thread = create(:communication_thread, account: account, assignee: former_owner, status: :open)
    account.account_users.find_by!(user: former_owner).destroy!
    foreign_account = create(:account)
    foreign_team = create(:team, account: foreign_account, name: 'Foreign team')
    thread.update_column(:team_id, foreign_team.id) # rubocop:disable Rails/SkipsModelValidations

    row = build_query({ dimension: 'owner' }).aggregate_rows.first
    detail = build_query({ dimension: 'owner' }).drill_down_rows.first

    expect(row[:attribution]).to include(id: former_owner.id, name: nil, state: 'unknown')
    expect(detail[:owner]).to include(id: former_owner.id, name: nil, state: 'unknown')
    expect(detail[:team]).to include(id: foreign_team.id, name: nil, state: 'unknown')
    expect(detail.to_json).not_to include('Former owner', 'Foreign team')
  end

  it 'shares filters and fingerprint across aggregate and bounded stable details' do
    owner = create(:user, account: account)
    matching = create(:communication_thread, account: account, assignee: owner, status: :pending, priority: :urgent,
                                             unread_count: 1)
    create(:communication_thread, account: account, assignee: owner, status: :open, priority: :urgent, unread_count: 1)
    create(:communication_thread, account: account, status: :pending, priority: :urgent, unread_count: 1)
    filters = { dimension: 'owner', assignee_id: owner.id, status: 'pending', priority: 'urgent', unread: 'with_unread' }

    aggregate = build_query(filters)
    details = build_query(filters.merge(page: 1, per_page: 1))

    expect(aggregate.aggregate_rows).to contain_exactly(include(unresolved_count: 1, pending_count: 1))
    expect(details.drill_down_rows).to contain_exactly(include(communication_thread_id: matching.id, status: 'pending', priority: 'urgent'))
    expect(details.pagination_meta[:total_count]).to eq(1)
    expect(aggregate.meta[:query_fingerprint]).to eq(details.pagination_meta[:query_fingerprint])
  end

  it 'supports explicit unassigned buckets and exact empty zero' do
    first = create(:communication_thread, account: account, status: :open)
    second = create(:communication_thread, account: account, status: :pending)
    create(:communication_thread, account: account, assignee: create(:user, account: account), status: :open)

    query = build_query({ dimension: 'owner', assignee_id: 'unassigned', page: 2, per_page: 1 })

    expect(query.aggregate_rows).to contain_exactly(include(unresolved_count: 2, attribution: include(id: nil, state: 'not_configured')))
    expect(query.drill_down_rows.pluck(:communication_thread_id)).to eq([second.id])
    expect(query.drill_down_rows.pluck(:communication_thread_id)).not_to include(first.id)

    empty = build_query({ status: 'snoozed' })
    expect(empty.aggregate_rows).to be_empty
    expect(empty.meta[:total_count]).to eq(0)
    expect(empty.drill_down_rows).to be_empty
  end

  it 'returns exact zero for a valid unassigned bucket with no visible matches' do
    create(:communication_thread, account: account, assignee: create(:user, account: account), status: :open)
    query = build_query({ dimension: 'owner', assignee_id: 'unassigned' })

    expect(query.aggregate_rows).to be_empty
    expect(query.meta[:total_count]).to eq(0)
    expect(query.drill_down_rows).to be_empty
    expect(query.pagination_meta[:total_count]).to eq(0)
  end

  it 'rejects historical, invalid, and foreign inputs' do
    foreign_owner = create(:user, account: create(:account))

    expect { build_query({ as_of: generated_at }) }.to raise_error(described_class::InvalidQuery, 'as_of is not supported for current snapshots')
    expect { build_query({ since: generated_at }) }.to raise_error(described_class::InvalidQuery, 'since is not supported for current snapshots')
    expect { build_query({ dimension: 'assignee' }) }.to raise_error(described_class::InvalidQuery, 'dimension must be owner or team')
    expect { build_query({ assignee_id: 1 }) }.to raise_error(described_class::InvalidQuery, 'dimension=owner is required with assignee_id')
    expect { build_query({ dimension: 'owner', assignee_id: foreign_owner.id }) }
      .to raise_error(described_class::InvalidQuery, 'assignee_id is invalid')
    expect { build_query({ status: 'resolved' }) }.to raise_error(described_class::InvalidQuery, 'status is invalid')
    expect { build_query({ unread: 'maybe' }) }.to raise_error(described_class::InvalidQuery, 'unread is invalid')
  end

  it 'rejects hidden attribution and unbounded pagination' do
    hidden_owner = create(:user, account: account)
    create(:communication_thread, account: account, assignee: hidden_owner)
    visible_scope = CommunicationThread.where(account_id: account.id, assignee_id: nil)

    expect { build_query({ dimension: 'owner', assignee_id: hidden_owner.id }, scope: visible_scope) }
      .to raise_error(described_class::InvalidQuery, 'assignee_id is invalid')
    expect { build_query({ page: 10_001 }).pagination_meta }.to raise_error(described_class::InvalidQuery, 'page must not exceed 10000')
    expect { build_query({ per_page: 101 }).pagination_meta }.to raise_error(described_class::InvalidQuery, 'per_page must not exceed 100')
  end
end
