# frozen_string_literal: true

# The numbers of one page of the organization list: how many accounts each organization has, how many operators they
# use and how many channels they have in total.
#
# The accounts of the whole page are read with ONE query and counted with the same grouped queries as the account list
# (SuperAdmin::AccountListStats), so a page of 20 organizations costs the same few queries as a page of 2. Storage is
# never read here.
#
#   stats = SuperAdmin::OrganizationListStats.new(organizations)
#   row = stats.for(organization)
#   row.accounts, row.operators, row.channels
class SuperAdmin::OrganizationListStats
  Row = Struct.new(:accounts, :operators, :channels, keyword_init: true)

  def initialize(organizations)
    ids = organizations.to_a.map(&:id)
    accounts = Account.where(organization_id: ids).order(:id).to_a
    @accounts_by_organization = accounts.group_by(&:organization_id)
    @account_stats = SuperAdmin::AccountListStats.new(accounts)
  end

  def for(organization)
    accounts = @accounts_by_organization.fetch(organization.id, [])
    Row.new(
      accounts: accounts.size,
      operators: accounts.sum { |account| @account_stats.operators_used(account) },
      channels: accounts.sum { |account| @account_stats.channels(account) }
    )
  end
end
