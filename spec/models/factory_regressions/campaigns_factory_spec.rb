require 'rails_helper'

RSpec.describe 'campaign factory' do
  it 'inherits the account from a provided inbox' do
    inbox = create(:inbox)

    campaign = build(:campaign, inbox: inbox)

    expect(campaign.account).to eq(inbox.account)
    expect(campaign.inbox).to eq(inbox)
  end
end
