require 'rails_helper'

RSpec.describe Scheduling::Appointments::AssignmentAuthorizer do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:other_user) { create(:user, account: account, role: :agent) }
  let(:other_contact) { create(:contact, account: account, owner: other_user) }
  let(:other_resource) { create(:scheduling_resource, account: account, user: other_user) }

  before do
    [agent, other_user].each(&:id)
    AccessControl::LegacyRoleAssigner.call(account: account, apply: true)
    AccessControl::ModeTransition.call(account: account, to: :shadow)
    AccessControl::ModeTransition.call(account: account, to: :enforced)
  end

  it 'allows an own-scoped manager to book an owned contact with any specialist' do
    appointment = build(
      :scheduling_appointment,
      account: account,
      contact: create(:contact, account: account, owner: agent),
      resource: other_resource
    )

    expect { described_class.call(account: account, actor: agent, appointment: appointment) }.not_to raise_error
  end

  it 'allows an own-scoped linked specialist to book their own resource' do
    appointment = build(
      :scheduling_appointment,
      account: account,
      contact: other_contact,
      resource: create(:scheduling_resource, account: account, user: agent)
    )

    expect { described_class.call(account: account, actor: agent, appointment: appointment) }.not_to raise_error
  end

  it 'rejects assignments outside the actor scope' do
    appointment = build(
      :scheduling_appointment,
      account: account,
      contact: other_contact,
      resource: other_resource
    )

    expect do
      described_class.call(account: account, actor: agent, appointment: appointment)
    end.to raise_error(Pundit::NotAuthorizedError)
  end

  it 'rejects assigning an owned contact to another owner with own scope' do
    appointment = build(
      :scheduling_appointment,
      account: account,
      contact: create(:contact, account: account, owner: agent),
      owner: other_user,
      resource: other_resource
    )

    expect do
      described_class.call(account: account, actor: agent, appointment: appointment)
    end.to raise_error(Pundit::NotAuthorizedError)
  end

  it 'allows assigning an owned contact to a teammate with team scope' do
    team = create(:team, account: account)
    create(:team_member, team: team, user: agent)
    create(:team_member, team: team, user: other_user)
    account.account_users.find_by!(user: agent).access_role.grants.find_by!(
      resource: 'appointments', capability: 'assign'
    ).update!(access_scope: 'team')
    appointment = build(
      :scheduling_appointment,
      account: account,
      contact: create(:contact, account: account, owner: agent),
      owner: other_user,
      resource: other_resource,
      team: team
    )

    expect { described_class.call(account: account, actor: agent, appointment: appointment) }.not_to raise_error
  end
end
