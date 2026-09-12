require 'rails_helper'

RSpec.describe Crm::Deals::RealtimeRecipients do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, :administrator, account: account) }
  let(:owner) { create(:user, account: account, role: :agent) }
  let(:other_agent) { create(:user, account: account, role: :agent) }
  let(:unrelated_agent) { create(:user, account: account, role: :agent) }

  before do
    administrator
    owner
    other_agent
    unrelated_agent
    enforce_access_roles!
  end

  it 'returns only users who can currently view the deal' do
    deal = create(:crm_deal, account: account, owner: owner)
    expect(AccessControl::ModeResolver).to receive(:mode_for_account).once.and_call_original
    expect(AccessControl::ModeResolver).not_to receive(:call)
    tokens = described_class.new(account: account, deal: deal).tokens

    expect(tokens).to contain_exactly(
      administrator.pubsub_token,
      owner.pubsub_token
    )
    expect(tokens).not_to include(unrelated_agent.pubsub_token)
  end

  it 'includes both old and new recipients when ownership changes' do
    deal = create(:crm_deal, account: account, owner: other_agent)

    tokens = described_class.new(
      account: account,
      deal: deal,
      changes: { 'owner_id' => [owner.id, other_agent.id] }
    ).tokens

    expect(tokens).to contain_exactly(administrator.pubsub_token, owner.pubsub_token, other_agent.pubsub_token)
  end

  it 'includes both old and new teams when the team boundary changes' do
    old_team = create(:team, account: account)
    new_team = create(:team, account: account)
    create(:team_member, team: old_team, user: owner)
    create(:team_member, team: new_team, user: other_agent)
    employee_role = owner.account_users.find_by!(account: account).access_role
    employee_role.grants.find_by!(resource: 'deals', capability: 'view').update!(access_scope: 'team')
    deal = create(:crm_deal, account: account, owner: nil, team: new_team)

    tokens = described_class.new(
      account: account,
      deal: deal,
      changes: { team_id: [old_team.id, new_team.id] }
    ).tokens

    expect(tokens).to contain_exactly(administrator.pubsub_token, owner.pubsub_token, other_agent.pubsub_token)
  end

  def enforce_access_roles!
    AccessControl::LegacyRoleAssigner.call(account: account, apply: true)
    AccessControl::ModeTransition.call(account: account, to: :shadow)
    AccessControl::ModeTransition.call(account: account, to: :enforced)
  end
end
