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

  def report_scope
    described_class::Scope.intersection(
      user_context,
      account.telephony_logical_call_occurrences,
      capabilities: %w[view view_reports]
    )
  end
end
