# frozen_string_literal: true

# The «Аккаунты» block of the organization card: one page of the accounts linked to the organization, the totals over ALL
# of them, and the accounts the super admin can link next.
#
#   * the linked accounts come 25 to a page (`accounts_page`, a page past the end shows the last one), by name; the
#     numbers of the rows of the page are read at once (SuperAdmin::AccountListStats);
#   * the totals (accounts, operators used and their limit, channels) are grouped SQL over every linked account
#     (SuperAdmin::OrganizationListStats), so they do not depend on the page;
#   * the accounts to link are the ones without an organization that match the search (a part of the name, or `#id`),
#     at most 20, so the picker stays small however many accounts there are.
#
#   block = SuperAdmin::OrganizationAccountsPage.new(organization, page: params[:accounts_page], search: params[:account_search])
#   block.rows        # => [[account, SuperAdmin::AccountListStats::Row], ...]
#   block.totals      # => accounts, operators_used, operators_limit, channels
#   block.candidates  # => [["Название · #12", 12], ...]
class SuperAdmin::OrganizationAccountsPage
  PER_PAGE = 25
  CANDIDATES = 20
  SEARCH_LENGTH = 100
  MAX_PAGE = 1_000_000

  Totals = Struct.new(:accounts, :operators_used, :operators_limit, :channels, keyword_init: true)

  # `search` is what the search box shows again
  attr_reader :organization, :search

  def initialize(organization, page: nil, search: nil)
    @organization = organization
    @page = page.is_a?(String) ? page.to_i.clamp(1, MAX_PAGE) : 1
    @search = search.is_a?(String) ? search.strip.first(SEARCH_LENGTH) : ''
  end

  # The linked accounts of the page, a Kaminari relation (the pager reads it)
  def accounts
    @accounts ||= begin
      scope = organization.accounts.order(:name, :id)
      page = scope.page(@page).per(PER_PAGE)
      page = scope.page(page.total_pages).per(PER_PAGE) if page.out_of_range? && page.total_pages.positive?
      page
    end
  end

  def paginated?
    accounts.total_pages > 1
  end

  # Each account of the page with the numbers of its row
  def rows
    @rows ||= begin
      list = accounts.to_a
      stats = SuperAdmin::AccountListStats.new(list)
      list.map { |account| [account, stats.for(account)] }
    end
  end

  # The totals of all linked accounts, not of the page. The limit is nil unless every account has one.
  def totals
    @totals ||= begin
      stats = SuperAdmin::OrganizationListStats.new([organization])
      row = stats.for(organization)
      Totals.new(accounts: row.accounts, operators_used: row.operators, operators_limit: stats.operators_limit(organization), channels: row.channels)
    end
  end

  # Is there an account without an organization at all (what «Все аккаунты уже привязаны» is about)
  def free_accounts?
    free_scope.exists?
  end

  # The accounts without an organization that match the search, as [label, id] for a select: at most CANDIDATES
  def candidates
    @candidates ||= matches.first(CANDIDATES).map { |name, id| ["#{name} · ##{id}", id] }
  end

  # Are there more matches than the picker shows (the search has to be narrower)
  def more_candidates?
    matches.size > CANDIDATES
  end

  private

  def free_scope
    Account.where(organization_id: nil)
  end

  # One more than the picker shows, to know whether there are more
  def matches
    @matches ||= searched(free_scope).order(:name, :id).limit(CANDIDATES + 1).pluck(:name, :id)
  end

  def searched(scope)
    return scope if search.empty?

    like = "%#{Account.sanitize_sql_like(search)}%"
    id = search[/\A#?(\d{1,9})\z/, 1]
    scope.where('accounts.name ILIKE :like OR accounts.id = :id', like: like, id: id&.to_i)
  end
end
