require 'rails_helper'

RSpec.describe Crm::Tasks::AssignmentAuthorizer do
  let(:account) { create(:account) }
  let(:actor) { create(:user, account: account) }
  let(:assignee) { create(:user, account: account) }
  let(:team) { create(:team, account: account) }

  it 'allows an account user assigned to an account team' do
    create(:team_member, team: team, user: assignee)

    expect(described_class.call(account: account, actor: actor, assignee: assignee, team: team)).to be(true)
  end

  it 'rejects an assignee outside the account' do
    outsider = create(:user)

    expect do
      described_class.call(account: account, actor: actor, assignee: outsider, team: nil)
    end.to raise_error(Crm::Error, 'Task assignee or team is outside the account assignment scope')
  end

  it 'rejects an assignee who is not a member of the selected team' do
    expect do
      described_class.call(account: account, actor: actor, assignee: assignee, team: team)
    end.to raise_error(Crm::Error, 'Task assignee or team is outside the account assignment scope')
  end

  it 'preserves system writes without an actor' do
    expect(described_class.call(account: account, actor: nil, assignee: assignee, team: nil)).to be(true)
  end
end
