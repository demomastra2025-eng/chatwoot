require 'rails_helper'

RSpec.describe Scheduling::AppointmentPolicy, type: :policy do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:account_user) { agent.account_users.find_by!(account: account) }
  let(:user_context) { { user: agent, account: account, account_user: account_user } }
  let(:other_user) { create(:user, account: account, role: :agent) }
  let(:own_contact) { create(:contact, account: account, owner: agent) }
  let(:other_contact) { create(:contact, account: account, owner: other_user) }
  let(:own_resource) { create(:scheduling_resource, account: account, user: agent) }
  let(:other_resource) { create(:scheduling_resource, account: account, user: other_user) }
  let!(:contact_owned_appointment) do
    create(:scheduling_appointment, account: account, contact: own_contact, resource: other_resource)
  end
  let!(:specialist_owned_appointment) do
    create(:scheduling_appointment, account: account, contact: other_contact, resource: own_resource)
  end
  let!(:other_appointment) do
    create(:scheduling_appointment, account: account, contact: other_contact, resource: other_resource)
  end

  it 'preserves account-wide legacy access' do
    expect(resolved_scope).to contain_exactly(contact_owned_appointment, specialist_owned_appointment, other_appointment)
    expect(described_class.new(user_context, other_appointment).update?).to be(true)
  end

  it 'treats the contact manager and linked specialist user as own in enforced mode' do
    bootstrap_roles!
    account_user.reload.access_role.grants.find_by!(resource: 'appointments', capability: 'view').update!(access_scope: 'own')

    expect(resolved_scope).to contain_exactly(contact_owned_appointment, specialist_owned_appointment)
    expect(described_class.new(user_context, other_appointment).show?).to be(false)
  end

  it 'adds appointments materialized to a member team for team scope' do
    bootstrap_roles!
    account_user.reload.access_role.grants.where(resource: 'appointments').find_each do |grant|
      grant.update!(access_scope: 'team')
    end
    team = create(:team, account: account)
    create(:team_member, team: team, user: agent)
    team_appointment = create(:scheduling_appointment, account: account, team: team)

    expect(resolved_scope).to contain_exactly(contact_owned_appointment, specialist_owned_appointment, team_appointment)
  end

  it 'keeps view and mutation capabilities independent' do
    bootstrap_roles!
    role = account_user.reload.access_role
    role.grants.where(resource: 'appointments').find_each { |grant| grant.update!(access_scope: 'none') }
    role.grants.find_by!(resource: 'appointments', capability: 'view').update!(access_scope: 'all')

    policy = described_class.new(user_context, other_appointment)

    expect(policy.show?).to be(true)
    expect(policy.update?).to be(false)
    expect(policy.assign?).to be(false)
    expect(policy.transition?).to be(false)
    expect(policy.manage_finance?).to be(false)
  end

  it 'intersects view and view_reports scopes for reporting' do
    bootstrap_roles!
    role = account_user.reload.access_role
    role.grants.find_by!(resource: 'appointments', capability: 'view').update!(access_scope: 'all')
    role.grants.create!(account: account, resource: 'appointments', capability: 'view_reports', access_scope: 'own')

    report_scope = described_class::Scope.intersection(
      user_context,
      account.scheduling_appointments,
      capabilities: %w[view view_reports]
    )

    expect(report_scope).to contain_exactly(contact_owned_appointment, specialist_owned_appointment)
  end

  it 'fails report intersection closed when either capability is none' do
    bootstrap_roles!
    role = account_user.reload.access_role
    role.grants.find_by!(resource: 'appointments', capability: 'view').update!(access_scope: 'none')
    role.grants.create!(account: account, resource: 'appointments', capability: 'view_reports', access_scope: 'all')

    report_scope = described_class::Scope.intersection(
      user_context,
      account.scheduling_appointments,
      capabilities: %w[view view_reports]
    )

    expect(report_scope).to be_empty
  end

  it 'account-qualifies Contact and Resource ownership for own and team scopes' do
    foreign_account = create(:account)
    create(:account_user, account: foreign_account, user: agent, role: :agent)
    foreign_contact = create(:contact, account: foreign_account, owner: agent)
    foreign_resource = create(:scheduling_resource, account: foreign_account, user: agent)
    corrupt_contact = create(:scheduling_appointment, account: account)
    corrupt_resource = create(:scheduling_appointment, account: account)
    corrupt_contact.update_columns(contact_id: foreign_contact.id) # rubocop:disable Rails/SkipsModelValidations
    corrupt_resource.update_columns(resource_id: foreign_resource.id) # rubocop:disable Rails/SkipsModelValidations
    bootstrap_roles!
    grant = account_user.reload.access_role.grants.find_by!(resource: 'appointments', capability: 'view')

    %w[own team].each do |access_scope|
      grant.update!(access_scope: access_scope)
      scope = described_class::Scope.new(
        user_context,
        account.scheduling_appointments.where(id: [corrupt_contact.id, corrupt_resource.id]),
        capability: 'view'
      ).resolve
      expect(scope).to be_empty
    end
  end

  it 'normalizes Team ids in deterministic order before building a team scope' do
    first_team = create(:team, account: account)
    second_team = create(:team, account: account)
    create(:team_member, team: second_team, user: agent)
    create(:team_member, team: first_team, user: agent)

    sql = described_class::Scope.apply(
      account.scheduling_appointments,
      access_scope: 'team',
      user: agent,
      account: account
    ).to_sql

    expect(sql).to include("team_id\" IN (#{first_team.id}, #{second_team.id})")
  end

  private

  def resolved_scope
    described_class::Scope.new(user_context, Scheduling::Appointment).resolve
  end

  def bootstrap_roles!
    AccessControl::LegacyRoleAssigner.call(account: account, apply: true)
    AccessControl::ModeTransition.call(account: account, to: :shadow)
    AccessControl::ModeTransition.call(account: account, to: :enforced)
  end
end
