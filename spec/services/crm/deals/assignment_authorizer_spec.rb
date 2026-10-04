require 'rails_helper'

RSpec.describe Crm::Deals::AssignmentAuthorizer do
  let(:account) { create(:account) }
  let(:actor) { create(:user, account: account) }
  let(:owner) { create(:user, account: account) }
  let(:team) { create(:team, account: account) }

  it 'allows account users assigned to an account team' do
    create(:team_member, team: team, user: owner)

    expect(described_class.call(account: account, actor: actor, owner: owner, team: team)).to be(true)
  end

  it 'rejects an owner outside the account' do
    outsider = create(:user)

    expect do
      described_class.call(account: account, actor: actor, owner: outsider, team: nil)
    end.to raise_error(Crm::Error, 'Deal owner or team is outside the account assignment scope')
  end

  it 'rejects an owner who is not a member of the selected team' do
    expect do
      described_class.call(account: account, actor: actor, owner: owner, team: team)
    end.to raise_error(Crm::Error, 'Deal owner or team is outside the account assignment scope')
  end

  it 'preserves system writes without an actor' do
    expect(described_class.call(account: account, actor: nil, owner: owner, team: nil)).to be(true)
  end
end
