require 'rails_helper'

RSpec.describe Scheduling::ScopeInvalidation do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }

  before do
    allow(described_class).to receive(:dispatch)
  end

  it 'invalidates appointment scopes when a contact owner changes' do
    contact = create(:contact, account: account)

    contact.update!(owner: user)

    expect(described_class).to have_received(:dispatch).with(account)
  end

  it 'invalidates appointment scopes when a resource-linked user changes' do
    resource = create(:scheduling_resource, account: account)

    resource.update!(user: user)

    expect(described_class).to have_received(:dispatch).with(account)
  end

  it 'invalidates appointment scopes when a team member is added or removed' do
    team = create(:team, account: account)
    membership = team.team_members.create!(user: user)

    expect(described_class).to have_received(:dispatch).with(account).once

    membership.destroy!

    expect(described_class).to have_received(:dispatch).with(account).twice
  end
end
