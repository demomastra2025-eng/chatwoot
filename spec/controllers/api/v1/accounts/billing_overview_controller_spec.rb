require 'rails_helper'

RSpec.describe Api::V1::Accounts::BillingOverviewController, type: :request do
  let(:account) { create(:account, limits: { agents: 7, storage_bytes: 2.gigabytes }) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:path) { "/api/v1/accounts/#{account.id}/billing_overview" }

  it 'requires authentication' do
    get path

    expect(response).to have_http_status(:unauthorized)
  end

  it 'allows only workspace administrators' do
    get path, headers: agent.create_new_auth_token, as: :json

    expect(response).to have_http_status(:unauthorized)
  end

  it 'returns legacy limits when the workspace is not linked' do
    get path, headers: admin.create_new_auth_token, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'configured' => false,
      'billing_account' => nil,
      'subscription' => nil,
      'workspace' => include('id' => account.id, 'name' => account.name)
    )
    expect(response.parsed_body['limits']).to include(
      include('key' => 'agents', 'value' => 7, 'source' => 'legacy')
    )
  end

  it 'returns the billing organization, subscription snapshot, and workspace allocations' do
    billing_account = create(:billing_account, name: 'Acme Billing')
    create(:billing_account_workspace, billing_account: billing_account, account: account)
    create(:billing_account_membership, billing_account: billing_account, user: admin)
    subscription = create(:billing_subscription, billing_account: billing_account)
    create(
      :billing_entitlement_allocation,
      billing_subscription: subscription,
      account: account,
      limits: { 'agents' => 12, 'storage_bytes' => 5.gigabytes }
    )

    get path, headers: admin.create_new_auth_token, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'configured' => true,
      'billing_account' => include('id' => billing_account.id, 'name' => 'Acme Billing'),
      'subscription' => include('status' => 'active', 'plan' => include('code' => subscription.billing_plan.code))
    )
    expect(response.parsed_body['limits']).to include(
      include('key' => 'agents', 'value' => 12, 'source' => 'billing_allocation'),
      include('key' => 'storage_bytes', 'value' => 5.gigabytes, 'source' => 'billing_allocation')
    )
  end

  it 'redacts organization-wide details from an administrator without a billing role' do
    billing_account = create(:billing_account)
    create(:billing_account_workspace, billing_account: billing_account, account: account)
    subscription = create(:billing_subscription, billing_account: billing_account)
    create(
      :billing_entitlement_allocation,
      billing_subscription: subscription,
      account: account,
      limits: { 'agents' => 3 }
    )

    get path, headers: admin.create_new_auth_token, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include('configured' => true, 'billing_account' => nil)
    expect(response.parsed_body.dig('billing_access', 'role')).to be_nil
    expect(response.parsed_body.dig('subscription', 'plan')).to be_present
    expect(response.parsed_body.dig('subscription', 'price')).to be_nil
  end

  it 'does not expose another workspace through the account-scoped route' do
    other_account = create(:account)

    get "/api/v1/accounts/#{other_account.id}/billing_overview", headers: admin.create_new_auth_token, as: :json

    expect(response).to have_http_status(:unauthorized)
  end
end
