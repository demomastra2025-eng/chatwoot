require 'rails_helper'

RSpec.describe Crm::Deals::RealtimeRecipients do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:deal) { create(:crm_deal, account: account, owner: agent) }

  it 'uses the existing CRM deal policy for every account member' do
    administrator
    agent
    expected_tokens = account.account_users.includes(:user).filter_map do |membership|
      user = membership.user
      next if user.blank? || user.pubsub_token.blank?

      user_context = { user: user, account: account, account_user: membership }
      user.pubsub_token if Crm::DealPolicy.new(user_context, deal).show?
    end

    expect(described_class.new(account: account, deal: deal).tokens).to match_array(expected_tokens)
  end

  it 'does not publish to a user outside the account membership' do
    outsider = create(:user, account: create(:account))
    deal

    expect(described_class.new(account: account, deal: deal).tokens).not_to include(outsider.pubsub_token)
  end
end
