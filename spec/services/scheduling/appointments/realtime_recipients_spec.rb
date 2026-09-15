require 'rails_helper'

RSpec.describe Scheduling::Appointments::RealtimeRecipients do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:other_user) { create(:user, account: account, role: :agent) }
  let(:third_user) { create(:user, account: account, role: :agent) }
  let(:owned_contact) { create(:contact, account: account, owner: agent) }
  let(:other_contact) { create(:contact, account: account, owner: other_user) }
  let(:resource) { create(:scheduling_resource, account: account, user: other_user) }
  let(:appointment) { create(:scheduling_appointment, account: account, contact: other_contact, resource: resource) }

  it 'uses the account channel before AccessRole enforcement' do
    expect(described_class.new(account: account, appointment: appointment).tokens).to eq(["account_#{account.id}"])
  end

  it 'targets current and previous own-scope users so revoked calendars refresh' do
    bootstrap_roles!
    AccountUser.where(account: account).includes(:access_role).find_each do |account_user|
      account_user.access_role.grants.find_by!(resource: 'appointments', capability: 'view').update!(access_scope: 'own')
    end

    tokens = described_class.new(
      account: account,
      appointment: appointment,
      changes: { contact_id: [owned_contact.id, other_contact.id] }
    ).tokens

    expect(tokens).to contain_exactly(agent.pubsub_token, other_user.pubsub_token)
    expect(tokens).not_to include(third_user.pubsub_token)
  end

  it 'targets members of both previous and current teams for team-scope moves' do
    bootstrap_roles!
    AccountUser.where(account: account).includes(:access_role).find_each do |account_user|
      account_user.access_role.grants.where(resource: 'appointments').find_each do |grant|
        grant.update!(access_scope: 'team')
      end
    end
    previous_team = create(:team, account: account)
    current_team = create(:team, account: account)
    create(:team_member, team: previous_team, user: agent)
    create(:team_member, team: current_team, user: third_user)
    appointment.update!(team_id: current_team.id)

    tokens = described_class.new(
      account: account,
      appointment: appointment,
      changes: { team_id: [previous_team.id, current_team.id] }
    ).tokens

    expect(tokens).to include(agent.pubsub_token, third_user.pubsub_token)
  end

  private

  def bootstrap_roles!
    [agent, other_user, third_user].each(&:id)
    AccessControl::LegacyRoleAssigner.call(account: account, apply: true)
    AccessControl::ModeTransition.call(account: account, to: :shadow)
    AccessControl::ModeTransition.call(account: account, to: :enforced)
  end
end
