require 'rails_helper'

RSpec.describe Telephony::LogicalCallOccurrencePolicy, type: :policy do
  let(:account) { create(:account) }
  let(:viewer) { create(:user, account: account, role: :agent) }
  let(:account_user) { account.account_users.find_by!(user: viewer) }
  let(:user_context) { { user: viewer, account: account, account_user: account_user } }
  let(:voice_inbox) { create(:channel_voice, :sipuni, account: account).inbox }
  let(:hidden_voice_inbox) { create(:channel_voice, :sipuni, account: account).inbox }
  let(:team) { create(:team, account: account) }

  def stub_scopes(view:, view_reports:, mode: 'enforced')
    scopes = { 'view' => view, 'view_reports' => view_reports }
    allow(described_class).to receive(:rbac_supported?).and_return(true)
    allow(AccessControl::ModeResolver).to receive(:call) do |account_user:, resource:, capability:|
      expect(account_user).to eq(self.account_user)
      expect(resource).to eq('telephony_calls')
      access_role_resolution = instance_double(AccessControl::ShadowResolver::Result, scope: scopes.fetch(capability))
      instance_double(
        AccessControl::ModeResolver::Result,
        account_id: account.id,
        mode: mode,
        authoritative_source: mode == 'enforced' ? 'access_role' : 'legacy',
        access_role_resolution: access_role_resolution
      )
    end
  end

  def create_source(ref:, inbox: voice_inbox, account_record: account)
    conversation = create(:conversation, account: account_record, inbox: inbox)
    create(
      :telephony_call_session,
      account: account_record,
      conversation: conversation,
      contact: conversation.contact,
      inbox: inbox,
      number_binding: nil,
      external_call_ref: ref,
      provider: 'sipuni',
      direction: 'inbound',
      started_at: nil,
      metadata: {}
    )
  end

  def insert_human_fact( # rubocop:disable Metrics/MethodLength
    identity:, actor:, actor_team: nil, inbox: voice_inbox, account_record: account
  )
    source = create_source(ref: identity, inbox: inbox, account_record: account_record)
    occurred_at = Time.utc(2026, 1, 10, 10)
    Telephony::LogicalCallOccurrence.insert_all!( # rubocop:disable Rails/SkipsModelValidations
      [{
        account_id: account_record.id,
        logical_call_identity: identity,
        logical_call_ref: identity,
        occurrence_kind: 'connected',
        source_kind: 'telephony_call_session',
        source_id: source.id,
        source_ref: source.external_call_ref,
        provider: source.provider,
        direction: source.direction,
        inbox_id_snapshot: inbox.id,
        actor_kind: 'human',
        actor_id_snapshot: actor.id,
        actor_name_snapshot: actor.name,
        actor_team_id_snapshot: actor_team&.id,
        actor_team_name_snapshot: actor_team&.name,
        occurred_at: occurred_at,
        connected_at: occurred_at,
        reliability: 'exact',
        reliable_since: occurred_at,
        source_version: 1,
        definition_version: 1,
        revision: 1,
        created_at: occurred_at
      }]
    )
    Telephony::LogicalCallOccurrence.find_by!(logical_call_identity: identity)
  end

  before do
    create(:inbox_member, inbox: voice_inbox, user: viewer)
    create(:team_member, team: team, user: viewer)
  end

  it 'requires non-none view and view_reports scopes in enforced mode' do
    stub_scopes(view: 'all', view_reports: 'none')
    expect(described_class.new(user_context, Telephony::LogicalCallOccurrence)).not_to be_view_reports

    stub_scopes(view: 'own', view_reports: 'team')
    expect(described_class.new(user_context, Telephony::LogicalCallOccurrence)).to be_view_reports
  end

  it 'preserves legacy administrator/report permission behavior before enforcement' do
    report_role = create(:custom_role, account: account, permissions: ['report_manage'])
    account_user.update!(custom_role: report_role)
    stub_scopes(view: 'none', view_reports: 'none', mode: 'legacy')

    expect(described_class.new(user_context, Telephony::LogicalCallOccurrence)).to be_view_reports
  end

  it 'fails closed in real shadow and enforced modes while telephony RBAC is unsupported' do
    fact = insert_human_fact(identity: 'rbac-unregistered', actor: viewer)
    administrator = create(:user, :administrator, account: account)
    admin_context = { user: administrator, account: account, account_user: account.account_users.find_by!(user: administrator) }

    expect(described_class.new(admin_context, Telephony::LogicalCallOccurrence)).to be_view_reports
    expect(described_class::Scope.new(admin_context, account.telephony_logical_call_occurrences).resolve).to include(fact)

    %w[shadow enforced].each do |mode|
      account.authorize_access_control_mode_transition { account.update!(access_control_mode: mode) }
      expect(described_class.new(admin_context, Telephony::LogicalCallOccurrence)).not_to be_view_reports
      expect(described_class::Scope.new(admin_context, account.telephony_logical_call_occurrences).resolve).to be_empty
    end
  end

  it 'intersects own, team, all and none over captured attribution and visible Voice inboxes' do
    teammate = create(:user, account: account)
    outsider = create(:user, account: account)
    own = insert_human_fact(identity: 'own', actor: viewer)
    team_fact = insert_human_fact(identity: 'team', actor: teammate, actor_team: team)
    outside = insert_human_fact(identity: 'outside', actor: outsider)
    hidden = insert_human_fact(identity: 'hidden-inbox', actor: viewer, inbox: hidden_voice_inbox)

    stub_scopes(view: 'all', view_reports: 'team')
    expect(report_scope).to contain_exactly(own, team_fact)

    stub_scopes(view: 'own', view_reports: 'all')
    expect(report_scope).to contain_exactly(own)

    stub_scopes(view: 'all', view_reports: 'all')
    expect(report_scope).to contain_exactly(own, team_fact, outside)
    expect(report_scope).not_to include(hidden)

    stub_scopes(view: 'none', view_reports: 'all')
    expect(report_scope).to be_empty
  end

  it 'never leaks foreign-account facts when both capability scopes are all' do
    foreign_account = create(:account)
    foreign_user = create(:user, account: foreign_account)
    foreign_inbox = create(:channel_voice, :sipuni, account: foreign_account).inbox
    foreign_fact = insert_human_fact(
      identity: 'foreign', actor: foreign_user, inbox: foreign_inbox, account_record: foreign_account
    )
    stub_scopes(view: 'all', view_reports: 'all')

    expect(report_scope).not_to include(foreign_fact)
  end

  it 'includes a late-linked attempted fact only with an immutable same-call visible Voice snapshot' do # rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength
    source = create(
      :telephony_call_session,
      account: account,
      inbox: nil,
      conversation: nil,
      contact: nil,
      number_binding: nil,
      provider: 'sipuni',
      direction: 'inbound',
      external_call_ref: 'sipuni:late-voice-link',
      status: 'ringing',
      started_at: Time.utc(2026, 1, 10, 10),
      from_number: '+155****0000', to_number: '+155****9999',
      metadata: {}
    )
    attempted = account.telephony_logical_call_occurrences.find_by!(occurrence_kind: 'attempted')
    stub_scopes(view: 'all', view_reports: 'all')
    expect(report_scope).not_to include(attempted)

    cutoff = Time.current.utc.iso8601(6)
    report_params = {
      from_local: '2026-01-01T00:00:00', to_local: '2026-02-01T00:00:00',
      as_of: cutoff, metric: 'attempted', dimension: 'inbox'
    }
    at_cutoff = report_query(report_params)
    expect(at_cutoff.aggregate_rows).to be_empty
    initial_fingerprint = at_cutoff.meta[:query_fingerprint]

    source.update!(inbox: voice_inbox, status: 'in_progress', answered_at: Time.utc(2026, 1, 10, 10, 5))
    expect(report_scope).to include(attempted)
    expect(report_scope(as_of: Time.iso8601(cutoff))).not_to include(attempted)
    expect(report_query(report_params).aggregate_rows).to be_empty
    expect(report_query(report_params).meta[:query_fingerprint]).to eq(initial_fingerprint)

    hidden = create(
      :telephony_call_session,
      account: account,
      inbox: nil, conversation: nil, contact: nil, number_binding: nil,
      provider: 'sipuni', direction: 'inbound', external_call_ref: 'sipuni:hidden-late-link',
      status: 'ringing', started_at: Time.utc(2026, 1, 10, 11), metadata: {},
      from_number: '+155****0000', to_number: '+155****9999'
    )
    hidden_attempted = account.telephony_logical_call_occurrences.find_by!(source_id: hidden.id, occurrence_kind: 'attempted')
    hidden.update!(inbox: hidden_voice_inbox, status: 'in_progress', answered_at: Time.utc(2026, 1, 10, 11, 5))
    expect(report_scope).not_to include(hidden_attempted)

    report = report_query(report_params.merge(as_of: Time.current.utc.iso8601(6)))
    expect(report.aggregate_rows.sum { |row| row[:total_count] }).to eq(1)
    expect(report.aggregate_rows.first[:bucket]).to eq(id: voice_inbox.id, state: 'captured')
    filtered = report_query(report_params.merge(as_of: Time.current.utc.iso8601(6), inbox_id: voice_inbox.id))
    expect(filtered.aggregate_rows.sum { |row| row[:total_count] }).to eq(1)
    expect(filtered.drill_down_rows.first).to include(
      occurrence_id: attempted.id, inbox_id_snapshot: nil, effective_inbox_id: voice_inbox.id
    )
    expect { report_query(report_params.merge(as_of: Time.current.utc.iso8601(6), inbox_id: hidden_voice_inbox.id)) }
      .to raise_error(Telephony::Error, /inbox_id is invalid/)
  end

  it 'resolves the as-of-current Voice link before applying inbox visibility on an A to B move' do # rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength
    second_agent = create(:user, account: account, role: :agent)
    create(:inbox_member, inbox: hidden_voice_inbox, user: second_agent)
    administrator = create(:user, :administrator, account: account)
    source = nil
    attempted = nil
    as_of_a = nil
    as_of_b = nil

    travel_to(Time.utc(2026, 9, 22, 11)) do
      source = create(
        :telephony_call_session,
        account: account,
        inbox: nil,
        conversation: nil,
        contact: nil,
        number_binding: nil,
        provider: 'sipuni',
        direction: 'inbound',
        external_call_ref: 'moved-inbox',
        status: 'ringing',
        started_at: Time.current,
        from_number: '+155****0000',
        to_number: '+155****9999',
        metadata: {}
      )
      attempted = account.telephony_logical_call_occurrences.find_by!(occurrence_kind: 'attempted', source_id: source.id)
    end
    travel_to(Time.utc(2026, 9, 22, 11, 5)) do
      source.update!(inbox: voice_inbox, status: 'in_progress', answered_at: Time.current)
      as_of_a = 1.second.from_now
    end
    travel_to(Time.utc(2026, 9, 22, 11, 10)) do
      source.update!(inbox: hidden_voice_inbox)
      as_of_b = 1.second.from_now
    end

    agent_a_scope = described_class::Scope.new(user_context, account.telephony_logical_call_occurrences)
    agent_b_context = { user: second_agent, account: account, account_user: account.account_users.find_by!(user: second_agent) }
    agent_b_scope = described_class::Scope.new(agent_b_context, account.telephony_logical_call_occurrences)
    admin_context = { user: administrator, account: account, account_user: account.account_users.find_by!(user: administrator) }
    admin_scope = described_class::Scope.new(admin_context, account.telephony_logical_call_occurrences)

    expect(agent_a_scope.resolve(as_of: as_of_a)).to include(attempted)
    expect(agent_b_scope.resolve(as_of: as_of_a)).not_to include(attempted)
    expect(admin_scope.resolve(as_of: as_of_a)).to include(attempted)
    expect(agent_a_scope.resolve(as_of: as_of_b)).not_to include(attempted)
    expect(agent_b_scope.resolve(as_of: as_of_b)).to include(attempted)
    expect(admin_scope.resolve(as_of: as_of_b)).to include(attempted)

    params = { from_local: '2026-09-01T00:00:00', to_local: '2026-10-01T00:00:00',
               as_of: as_of_b.iso8601(6), metric: 'attempted', dimension: 'inbox' }
    query_a = Telephony::Reports::LogicalCallsQuery.new(account: account, occurrences_scope: agent_a_scope, params: params)
    query_b = Telephony::Reports::LogicalCallsQuery.new(account: account, occurrences_scope: agent_b_scope, params: params)
    query_admin = Telephony::Reports::LogicalCallsQuery.new(account: account, occurrences_scope: admin_scope, params: params)
    expect(query_a.aggregate_rows).to be_empty
    expect(query_b.aggregate_rows.first[:bucket]).to eq(id: hidden_voice_inbox.id, state: 'captured')
    expect(query_b.drill_down_rows.first).to include(occurrence_id: attempted.id, effective_inbox_id: hidden_voice_inbox.id)
    expect(query_admin.aggregate_rows.first[:bucket]).to eq(id: hidden_voice_inbox.id, state: 'captured')
    expect do
      Telephony::Reports::LogicalCallsQuery.new(
        account: account, occurrences_scope: agent_a_scope, params: params.merge(inbox_id: hidden_voice_inbox.id)
      )
    end.to raise_error(Telephony::Error, /inbox_id is invalid/)
  end

  it 'never grants own scope from mutable binding or non-human attribution' do
    source = create_source(ref: 'ai')
    occurred_at = Time.utc(2026, 1, 10, 10)
    Telephony::LogicalCallOccurrence.insert_all!( # rubocop:disable Rails/SkipsModelValidations
      [{
        account_id: account.id,
        logical_call_identity: 'ai',
        logical_call_ref: 'ai',
        occurrence_kind: 'connected',
        source_kind: 'telephony_call_session',
        source_id: source.id,
        source_ref: source.external_call_ref,
        provider: source.provider,
        direction: source.direction,
        inbox_id_snapshot: voice_inbox.id,
        actor_kind: 'ai_agent',
        occurred_at: occurred_at,
        connected_at: occurred_at,
        reliability: 'exact',
        reliable_since: occurred_at,
        source_version: 1,
        definition_version: 1,
        revision: 1,
        created_at: occurred_at
      }]
    )
    stub_scopes(view: 'own', view_reports: 'own')

    expect(report_scope).to be_empty
  end

  def report_scope(as_of: Time.current)
    described_class::Scope.intersection(
      user_context,
      account.telephony_logical_call_occurrences,
      capabilities: %w[view view_reports], as_of: as_of
    )
  end

  def report_query(params)
    Telephony::Reports::LogicalCallsQuery.new(
      account: account,
      occurrences_scope: described_class::Scope.new(
        user_context, account.telephony_logical_call_occurrences, capabilities: %w[view view_reports]
      ),
      params: params
    )
  end
end
