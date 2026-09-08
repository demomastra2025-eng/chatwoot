require 'rails_helper'

RSpec.describe Billing::BootstrapWorkspaceService do
  subject(:bootstrap) { service.call }

  let(:account) { create(:account, name: 'Acme Workspace', locale: 'kk') }
  let(:owner) { create(:user) }
  let(:currency) { 'KZT' }
  let(:service) { described_class.new(account: account, owner: owner, currency: currency) }

  before do
    create(:account_user, account: account, user: owner, role: 'administrator')
  end

  it 'creates a billing account, owner membership, and active workspace link' do
    billing_account = bootstrap

    expect(billing_account).to have_attributes(
      name: 'Acme Workspace',
      default_currency: 'KZT',
      default_locale: 'kk'
    )
    expect(billing_account.memberships.sole).to have_attributes(user: owner, role: 'owner', status: 'active')
    expect(billing_account.workspace_links.sole).to have_attributes(account: account, status: 'active')
  end

  it 'is idempotent for an already linked workspace' do
    first_billing_account = service.call

    expect { service.call }.to not_change(BillingAccount, :count)
      .and not_change(BillingAccountMembership, :count)
      .and not_change(BillingAccountWorkspace, :count)
    expect(service.call).to eq(first_billing_account)
  end

  it 'rejects a user who is not a workspace administrator' do
    outsider = create(:user)
    service = described_class.new(account: account, owner: outsider)

    expect { service.call }.to raise_error(ArgumentError, 'owner must be an administrator of the workspace')
    expect(BillingAccountWorkspace.where(account: account)).to be_empty
  end

  it 'rolls back the whole bootstrap when billing data is invalid' do
    service = described_class.new(account: account, owner: owner, currency: 'invalid')

    expect { service.call }.to raise_error(ActiveRecord::RecordInvalid)
    expect(BillingAccount.where(name: account.name)).to be_empty
    expect(BillingAccountWorkspace.where(account: account)).to be_empty
  end

  it 'does not change the legacy workspace limits contract' do
    legacy_limits = account.usage_limits.deep_dup

    bootstrap

    expect(account.reload.usage_limits).to eq(legacy_limits)
  end
end
