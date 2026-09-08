class Billing::BootstrapWorkspaceService
  def initialize(account:, owner:, currency: 'KZT')
    @account = account
    @owner = owner
    @currency = currency
  end

  def call
    validate_owner!

    account.with_lock do
      existing_link = BillingAccountWorkspace.active.find_by(account_id: account.id)
      existing_link ? existing_link.billing_account : create_billing_account!
    end
  end

  private

  attr_reader :account, :owner, :currency

  def validate_owner!
    return if owner.present? && account.administrators.exists?(id: owner.id)

    raise ArgumentError, 'owner must be an administrator of the workspace'
  end

  def create_billing_account!
    billing_account = BillingAccount.create!(
      name: account.name,
      default_currency: currency,
      default_locale: account.locale.presence || I18n.default_locale.to_s
    )
    billing_account.memberships.create!(user: owner, role: 'owner', status: 'active')
    billing_account.workspace_links.create!(account: account, status: 'active')
    billing_account
  end
end
