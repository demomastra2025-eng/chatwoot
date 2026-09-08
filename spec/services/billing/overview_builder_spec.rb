require 'rails_helper'

RSpec.describe Billing::OverviewBuilder do
  subject(:payload) { described_class.new(account: account, user: admin).call }

  let(:account) { create(:account, limits: { agents: 7 }) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:payer) { create(:billing_account) }

  before do
    create(:billing_account_workspace, billing_account: payer, account: account)
    create(:billing_account_membership, billing_account: payer, user: admin)
  end

  it 'excludes SuperAdmin from workspace seat usage' do
    create(:account_user, account: account, user: create(:super_admin))

    expect(payload[:limits]).to include(include(key: 'agents', consumed: 1))
  end

  it 'counts unique ordinary users across active workspaces only' do
    second = create(:account)
    detached = create(:account)
    create(:billing_account_workspace, billing_account: payer, account: second)
    create(:billing_account_workspace, billing_account: payer, account: detached, status: 'detached', detached_at: Time.current)
    create(:account_user, account: second, user: admin)
    create(:user, account: second)
    create(:account_user, account: second, user: create(:super_admin))
    create(:user, account: detached)

    expect(payload[:billing_account][:unique_user_count]).to eq(2)
  end

  %w[incomplete suspended canceled].each do |status|
    it "displays #{status} without granting subscription allocations" do
      subscription = create(:billing_subscription, billing_account: payer)
      create(:billing_entitlement_allocation, billing_subscription: subscription, account: account, limits: { agents: 99 })
      subscription.update!(status: status)

      expect(payload[:subscription]).to include(status: status)
      expect(payload[:limits]).to include(include(key: 'agents', value: 7, source: :legacy))
    end
  end

  it 'does not expose payer details or price to a workspace administrator without a billing role' do
    payer.update!(legal_name: 'Private Payer', billing_email: 'private@example.test')
    payer.memberships.each { |membership| membership.update!(status: 'inactive') }
    create(:billing_subscription, billing_account: payer, status: 'suspended')

    expect(payload[:billing_account]).to be_nil
    expect(payload[:subscription][:status]).to eq('suspended')
    expect(payload[:subscription][:price]).to be_nil
    expect(payload.to_json).not_to include('Private Payer', 'private@example.test')
  end
end
