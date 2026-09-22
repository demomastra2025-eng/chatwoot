# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CommunicationThreadPolicy, type: :policy do
  let(:account) do
    create(:account).tap do |record|
      record.enable_features!('communication_threads')
      AccessControl::SystemRoleBootstrapper.call(account: record)
    end
  end
  let(:participant) { create(:user, account: account, role: :agent) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let(:communication_thread) { conversation.reload.communication_thread }
  let(:user_context) do
    {
      user: participant,
      account: account,
      account_user: account.account_users.find_by!(user: participant)
    }
  end

  before do
    CommunicationThreadParticipant.create!(
      account: account,
      communication_thread: communication_thread,
      user: participant
    )
    AccessControl::ModeTransition.call(account: account, to: :shadow)
    AccessControl::ModeTransition.call(account: account, to: :enforced)
  end

  it 'allows a participant to view and reply without granting dialog management' do
    policy = described_class.new(user_context, communication_thread)

    expect(policy).to be_show
    expect(policy).to be_reply
    expect(policy).not_to be_transition
    expect(policy).not_to be_update
    expect(policy).not_to be_assign
  end

  it 'includes the participant thread in the view scope' do
    scope = described_class::Scope.new(user_context, CommunicationThread.all).resolve

    expect(scope).to include(communication_thread)
  end

  it 'excludes participant-only visibility from owner workload intersections' do
    scope = described_class::Scope.intersection(
      user_context,
      CommunicationThread.where(account_id: account.id),
      capabilities: %w[view view_reports]
    )

    expect(scope).not_to include(communication_thread)
  end

  it 'authorizes reports from conversations:view_reports independently of participant access' do
    account_user = user_context.fetch(:account_user)
    report_grant = account_user.access_role.grants.find_or_initialize_by(
      account: account,
      resource: 'conversations',
      capability: 'view_reports'
    )
    report_grant.update!(access_scope: 'own')

    expect(described_class.new(user_context, CommunicationThread)).to be_view_reports
  end

  it 'instruments the legacy account-wide scope while AccessRole scopes are in shadow mode' do
    mode_resolution = instance_double(
      AccessControl::ModeResolver::Result,
      mode: 'shadow',
      authoritative_source: 'legacy'
    )
    allow(AccessControl::ModeResolver).to receive(:call).and_return(mode_resolution)
    expect(AccessControl::ModeAwareDecision).to receive(:instrument_shadow_scope).with(
      mode_resolution: mode_resolution,
      legacy_scope: 'all'
    )

    described_class::Scope.new(
      user_context,
      CommunicationThread.where(account_id: account.id),
      capability: 'view_reports',
      owner_only: true
    ).resolve
  end

  it 'keeps a directly assigned thread visible in a prefetched team scope' do
    communication_thread.communication_thread_participants.delete_all
    communication_thread.update!(assignee: participant, team: nil)
    access_role_resolution = instance_double(AccessControl::ShadowResolver::Result, scope: 'team')
    mode_resolution = instance_double(
      AccessControl::ModeResolver::Result,
      mode: 'enforced',
      access_role_resolution: access_role_resolution
    )
    snapshot_context = user_context.merge(
      thread_access_snapshot: {
        participant: false,
        team_ids: [],
        mode_resolutions: { 'view' => mode_resolution }
      }
    )

    expect(described_class.new(snapshot_context, communication_thread)).to be_show
  end
end
