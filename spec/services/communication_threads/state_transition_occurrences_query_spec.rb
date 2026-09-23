require 'rails_helper'

RSpec.describe CommunicationThreads::StateTransitionOccurrencesQuery do
  let(:account) { create(:account, settings: { 'workspace_timezone' => 'Asia/Almaty' }) }
  let(:viewer) { create(:user, :administrator, account: account) }
  let(:generated_at) { 2.hours.from_now }
  let(:params) { { from_date: '2026-09-22', to_date: '2026-09-22' } }
  let(:user_context) do
    { user: viewer, account: account, account_user: account.account_users.find_by!(user: viewer) }
  end

  before { account.enable_features!('communication_threads') }

  def query(options = {}, context: user_context, account_record: account, **filters)
    described_class.new(account: account_record, user_context: context, params: params.merge(options).merge(filters), generated_at: generated_at)
  end

  def thread_fact(thread:, at: Time.utc(2026, 9, 22, 12), **attributes)
    create(:communication_thread_state_transition_fact,
           account: thread.account,
           communication_thread_id_snapshot: thread.id,
           thread_display_id_snapshot: thread.display_id,
           contact_id_snapshot: thread.contact_id,
           occurred_at: at, requested_occurred_at: at, reliable_since: at,
           **attributes)
  end

  def enforce_scope!(capability, scope)
    grant = user_context.fetch(:account_user).access_role.grants.find_or_initialize_by(
      account: account, resource: 'conversations', capability: capability
    )
    grant.update!(access_scope: scope)
  end

  def enable_enforced_access!
    AccessControl::LegacyRoleAssigner.call(account: account, apply: true)
    AccessControl::ModeTransition.call(account: account, to: :shadow)
    AccessControl::ModeTransition.call(account: account, to: :enforced)
  end

  it 'counts immutable assignment and resolution occurrences independently of later current owner, actor and channel routing' do # rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
    old_owner = create(:user, account: account, name: 'Former owner')
    next_owner = create(:user, account: account, name: 'New owner')
    acting_user = create(:user, account: account, name: 'Different actor')
    first_team = create(:team, account: account, name: 'First team')
    next_team = create(:team, account: account, name: 'Next team')
    thread = create(:communication_thread, account: account, assignee: next_owner)
    create_list(:communication_thread_conversation, 2, account: account, communication_thread: thread)
    initial = thread_fact(thread: thread, event_kind: 'created', to_assignee_id: old_owner.id,
                          to_assignee_name: old_owner.name, to_team_id: first_team.id,
                          to_team_name: first_team.name)
    reassigned = thread_fact(thread: thread, at: initial.occurred_at + 1.second,
                             event_kind: 'routing_changed', from_status: 'open',
                             from_assignee_id: old_owner.id, from_assignee_name: old_owner.name,
                             to_assignee_id: next_owner.id, to_assignee_name: next_owner.name,
                             from_team_id: first_team.id, from_team_name: first_team.name,
                             to_team_id: next_team.id, to_team_name: next_team.name,
                             actor_kind: 'user', actor_id: acting_user.id, actor_name: acting_user.name)
    resolved = thread_fact(thread: thread, at: initial.occurred_at + 2.seconds,
                           event_kind: 'resolved', from_status: 'open', to_status: 'resolved',
                           from_assignee_id: next_owner.id, to_assignee_id: next_owner.id,
                           to_assignee_name: next_owner.name, actor_kind: 'system', actor_id: nil)
    thread_fact(thread: thread, at: initial.occurred_at + 3.seconds,
                event_kind: 'reopened', from_status: 'resolved', to_status: 'open',
                from_assignee_id: next_owner.id, to_assignee_id: next_owner.id, to_assignee_name: next_owner.name)
    thread_fact(thread: thread, at: initial.occurred_at + 4.seconds,
                event_kind: 'routing_changed', from_status: 'open',
                from_assignee_id: next_owner.id, from_assignee_name: next_owner.name,
                from_team_id: next_team.id, from_team_name: next_team.name)
    thread_fact(thread: thread, at: initial.occurred_at + 5.seconds,
                event_kind: 'routing_changed', from_status: 'open',
                to_assignee_id: next_owner.id, to_assignee_name: next_owner.name)

    report = query(dimension: 'owner')
    buckets = report.aggregate_rows.index_by { |row| row.dig(:attribution, :id) }
    expect(report.meta).to include(observed_count: 6, occurrence_total: nil, coverage: 'partial',
                                   verified_writer_cutover_at: nil, fallback_count: 0,
                                   effectiveness_state: 'historical_sla_duration_rates_and_denominator_not_supported')
    expect(buckets.fetch(old_owner.id)).to include(occurrence_count: 1, created_count: 1, assigned_count: 1)
    expect(buckets.fetch(next_owner.id)).to include(
      occurrence_count: 4, assigned_count: 1, reassigned_count: 1, resolved_count: 1, reopened_count: 1
    )
    expect(buckets.fetch(nil)).to include(occurrence_count: 1, unassigned_count: 1)
    expect(report.drill_down_rows.pluck(:fact_id).size).to eq(6)
    matching = query(dimension: 'owner', owner_id: next_owner.id)
    expect(matching.aggregate_rows.sole).to include(occurrence_count: 4, resolved_count: 1)
    expect(matching.pagination_meta[:total_count]).to eq(4)
    expect(matching.drill_down_rows.pluck(:fact_id)).to include(reassigned.id, resolved.id)
    expect(matching.drill_down_rows.find { |row| row[:fact_id] == reassigned.id }).to include(
      owner_transition: 'reassigned', team_transition: 'reassigned',
      actor: { kind: 'user', id: acting_user.id, name_snapshot: acting_user.name },
      from_owner: include(id: old_owner.id, name_snapshot: old_owner.name)
    )
    expect(query(dimension: 'team', team_id: next_team.id).aggregate_rows.sole).to include(reassigned_count: 1)
    expect(report.meta[:query_fingerprint]).to eq(query(dimension: 'owner').meta[:query_fingerprint])
    expect(query(dimension: 'team').meta[:query_fingerprint]).not_to eq(report.meta[:query_fingerprint])
  end

  it 'keeps former and deactivated owner/team snapshots, without using current catalog names' do
    owner = create(:user, account: account, name: 'Historic employee')
    team = create(:team, account: account, name: 'Historic team')
    thread = create(:communication_thread, account: account)
    original = thread_fact(thread: thread, to_assignee_id: owner.id, to_assignee_name: owner.name,
                           to_team_id: team.id, to_team_name: team.name)
    owner.account_users.find_by!(account: account).update!(availability: :offline)
    owner.update!(name: 'Current name')
    team.destroy!
    owner.account_users.find_by!(account: account).destroy!

    rows = query(dimension: 'owner', owner_id: owner.id).drill_down_rows
    expect(rows.sole).to include(fact_id: original.id,
                                 to_owner: { id: owner.id, name_snapshot: 'Historic employee', state: 'persisted_snapshot' },
                                 to_team: { id: team.id, name_snapshot: 'historic team', state: 'persisted_snapshot' })
    expect(rows.to_json).not_to include('Current name')
    expect(query(dimension: 'team', team_id: team.id).aggregate_rows.sole.dig(:attribution, :id)).to eq(team.id)
  end

  it 'distinguishes empty observed history from exact zero, including legacy and fallback coverage' do
    empty = query
    expect(empty.aggregate_rows).to be_empty
    expect(empty.drill_down_rows).to be_empty
    expect(empty.meta).to include(observed_count: 0, total_count: 0, occurrence_total: nil,
                                  coverage: 'unknown', verified_writer_cutover_at: nil,
                                  first_observed_reliable_since: nil)
    thread = create(:communication_thread, account: account)
    fact = thread_fact(thread: thread, source: 'database_projection_fallback', request_fingerprint: nil)
    expect(query.meta).to include(observed_count: 1, coverage: 'partial', fallback_count: 1,
                                  first_observed_reliable_since: fact.occurred_at.iso8601(6))
    expect(query.drill_down_rows.sole).to include(source: 'database_projection_fallback', source_version: 1)
    expect(query(dimension: 'team', team_id: 'unassigned').aggregate_rows.sole).to include(
      occurrence_count: 1, attribution: include(state: 'not_configured')
    )
    thread_fact(thread: thread, at: fact.occurred_at + 1.second, source: 'spec_command',
                event_kind: 'state_changed', from_status: 'open', to_status: 'pending')
    expect(query.meta).to include(observed_count: 2, coverage: 'partial', fallback_count: 1, unknown_version_count: 0)
  end

  it 'does not substitute an absent actor for the historical owner or expose a name for a nil identity' do
    owner = create(:user, account: account)
    thread = create(:communication_thread, account: account)
    fact = thread_fact(thread: thread, to_assignee_id: owner.id, actor_kind: 'unknown', actor_id: nil, actor_name: nil,
                       to_team_name: 'must not expose this name without an identity')

    expect(query.drill_down_rows.sole).to include(
      fact_id: fact.id,
      to_owner: { id: owner.id, name_snapshot: nil, state: 'unknown_snapshot_name' },
      to_team: { id: nil, name_snapshot: nil, state: 'not_configured' },
      actor: { kind: 'unknown', id: nil, name_snapshot: nil }
    )
  end

  it 'dedupes writer retries and orders bounded pages stably with aggregate-to-details parity' do
    thread = create(:communication_thread, account: account)
    at = 1.minute.since(Time.current)
    first_writer = CommunicationThreads::StateTransitionWriter.new(
      thread: thread, attributes: { status: 'resolved' }, source: 'spec_command',
      source_record: thread, source_event_id: SecureRandom.uuid, occurred_at: at
    )
    fact = first_writer.perform
    expect(first_writer.perform).to eq(fact)
    local_day = fact.occurred_at.in_time_zone(account.workspace_working_hours_timezone).to_date.iso8601
    filters = { from_date: local_day, to_date: local_day, event_kind: 'resolved', dimension: 'owner' }
    3.times do |index|
      another = create(:communication_thread, account: account)
      CommunicationThreads::StateTransitionWriter.new(
        thread: another, attributes: { status: 'resolved' }, source: 'spec_command',
        source_event_id: SecureRandom.uuid, occurred_at: (index + 1).seconds.since(at)
      ).perform
    end
    aggregate = query(filters)
    ids = (1..4).flat_map do |page_number|
      page_query = query(filters.merge(page: page_number, per_page: 1))
      expect(page_query.pagination_meta[:query_fingerprint]).to eq(aggregate.meta[:query_fingerprint])
      expect(page_query.pagination_meta[:total_count]).to eq(4)
      page_query.drill_down_rows.pluck(:fact_id)
    end
    expect(ids.uniq.size).to eq(4)
    expect(ids).to eq(query(filters).drill_down_rows.pluck(:fact_id))
    expect(aggregate.aggregate_rows.sole[:occurrence_count]).to eq(ids.size)
  end

  it 'intersects own/team/all/none and denies participant-only fact and hidden filter oracles' do
    teammate = create(:user, account: account)
    outsider = create(:user, account: account)
    team = create(:team, account: account)
    create(:team_member, team: team, user: viewer)
    own = create(:communication_thread, account: account, assignee: viewer)
    team_thread = create(:communication_thread, account: account, assignee: teammate, team: team)
    hidden = create(:communication_thread, account: account, assignee: outsider)
    participant_only = create(:communication_thread, account: account, assignee: outsider)
    create(:communication_thread_participant, account: account, communication_thread: participant_only, user: viewer)
    [own, team_thread, hidden, participant_only].each do |thread|
      thread_fact(thread: thread, to_assignee_id: thread.assignee_id,
                  to_assignee_name: thread.assignee.name)
    end
    enable_enforced_access!
    enforce_scope!('view', 'own')
    enforce_scope!('view_reports', 'all')
    expect(query.drill_down_rows.pluck(:communication_thread_id)).to eq([own.id])
    expect { query(dimension: 'owner', owner_id: outsider.id) }
      .to raise_error(described_class::InvalidQuery, 'owner_id is invalid')
    foreign_id = create(:user, account: create(:account)).id
    expect { query(dimension: 'owner', owner_id: foreign_id) }
      .to raise_error(described_class::InvalidQuery, 'owner_id is invalid')
    enforce_scope!('view', 'all')
    enforce_scope!('view_reports', 'team')
    expect(query.drill_down_rows.pluck(:communication_thread_id)).to contain_exactly(own.id, team_thread.id)
    enforce_scope!('view_reports', 'all')
    expect(query.drill_down_rows.pluck(:communication_thread_id)).to contain_exactly(own.id, team_thread.id, hidden.id, participant_only.id)
    enforce_scope!('view', 'none')
    expect(query.meta).to include(observed_count: 0, coverage: 'unknown')
    enforce_scope!('view', 'all')
    enforce_scope!('view_reports', 'none')
    expect { query }.to raise_error(Pundit::NotAuthorizedError)
  end

  it 'denies deleted and corrupt thread/contact snapshots and foreign-tenant facts' do
    foreign_account = create(:account)
    foreign_thread = create(:communication_thread, account: foreign_account)
    thread_fact(thread: foreign_thread)
    deleted = create(:communication_thread, account: account)
    thread_fact(thread: deleted)
    deleted.destroy!
    corrupt = create(:communication_thread, account: account)
    thread_fact(thread: corrupt)
    foreign_contact = create(:contact, account: foreign_account)
    corrupt.update_column(:contact_id, foreign_contact.id) # rubocop:disable Rails/SkipsModelValidations
    visible = create(:communication_thread, account: account)
    fact = thread_fact(thread: visible)
    expect(query.drill_down_rows.pluck(:fact_id)).to eq([fact.id])
    expect(query.aggregate_rows).to all(include(occurrence_count: 1))
  end

  it 'uses adjacent workspace-local half-open days across the DST spring-forward boundary' do
    account.update!(settings: account.settings.merge('workspace_timezone' => 'America/New_York'))
    thread = create(:communication_thread, account: account)
    before = thread_fact(thread: thread, at: Time.utc(2026, 3, 8, 4, 59, 59, 999_999))
    start = thread_fact(thread: thread, at: Time.utc(2026, 3, 8, 5))
    finish = thread_fact(thread: thread, at: Time.utc(2026, 3, 9, 3, 59, 59, 999_999))
    after = thread_fact(thread: thread, at: Time.utc(2026, 3, 9, 4))
    first_day = query({ from_date: '2026-03-07', to_date: '2026-03-07' })
    dst_day = query({ from_date: '2026-03-08', to_date: '2026-03-08' })
    next_day = query({ from_date: '2026-03-09', to_date: '2026-03-09' })
    expect(first_day.drill_down_rows.pluck(:fact_id)).to eq([before.id])
    expect(dst_day.drill_down_rows.pluck(:fact_id)).to eq([finish.id, start.id])
    expect(next_day.drill_down_rows.pluck(:fact_id)).to eq([after.id])
    expect(dst_day.meta).to include(from: '2026-03-08T05:00:00.000000Z', to: '2026-03-09T04:00:00.000000Z')
  end

  it 'rejects unauthorized caller contexts, invalid windows and unsupported historical as_of claims' do # rubocop:disable RSpec/MultipleExpectations
    expect { query(context: user_context.merge(account_user: nil)) }.to raise_error(Pundit::NotAuthorizedError)
    expect { query(context: user_context.merge(account: create(:account))) }.to raise_error(Pundit::NotAuthorizedError)
    account.disable_features!('communication_threads')
    expect { query }.to raise_error(Pundit::NotAuthorizedError)
    account.enable_features!('communication_threads')
    expect { query({ as_of: '2026-09-22' }) }.to raise_error(described_class::InvalidQuery, 'unsupported report parameter')
    expect { query({ to_date: '2026-09-21' }) }.to raise_error(described_class::InvalidQuery, /to_date must be on/)
    expect { query({ from_date: '2026-02-30' }) }.to raise_error(described_class::InvalidQuery, /valid date/)
    expect { query({ per_page: 101 }) }.to raise_error(described_class::InvalidQuery, /per_page must not exceed/)
    expect { query({ page: 10_001 }) }.to raise_error(described_class::InvalidQuery, /page must not exceed/)
    expect { query({ dimension: 'owner', team_id: 1 }) }.to raise_error(described_class::InvalidQuery, /dimension=team/)
    user_context.fetch(:account_user).destroy!
    expect { query }.to raise_error(Pundit::NotAuthorizedError)
  end
end
