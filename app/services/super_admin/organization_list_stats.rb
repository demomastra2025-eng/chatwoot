# frozen_string_literal: true

# The numbers of organizations: how many accounts each one has, how many operators they use and how many channels they
# have in total (and, on demand, the sum of their operator limits).
#
# Every number is one grouped query by organization (`GROUP BY accounts.organization_id`) over the organizations given,
# so a page of 20 organizations costs the same few queries as a page of 2, and an organization with thousands of accounts
# costs the same as one with three: no account is loaded into Ruby. The card of an organization reads its totals the same
# way (`OrganizationListStats.new([organization])`), over ALL its accounts. Storage is never read here.
#
# The operators are counted the way AccountListStats counts them (and the limit does): the members of the accounts, minus
# the ones the account excludes (custom_attributes `limit_counter_excluded_user_ids`). The limit follows
# AccountListStats#operators_limit: the subscribed quantity, else the limit of the account itself, else the installation
# limit; a spec compares them.
#
#   stats = SuperAdmin::OrganizationListStats.new(organizations)
#   row = stats.for(organization)
#   row.accounts, row.operators, row.channels
#   stats.operators_limit(organization) # the sum of the limits, nil when some account has none (or there is no account)
class SuperAdmin::OrganizationListStats
  Row = Struct.new(:accounts, :operators, :channels, keyword_init: true)

  # The members of an account that its limit does not count: the user ids listed in custom_attributes. A value that is
  # not a list excludes nobody (the account form only ever writes a list of numbers).
  EXCLUDED_MEMBER_SQL = <<~SQL.squish
    EXISTS (
      SELECT 1
      FROM jsonb_array_elements_text(
        CASE WHEN jsonb_typeof(accounts.custom_attributes -> 'limit_counter_excluded_user_ids') = 'array'
             THEN accounts.custom_attributes -> 'limit_counter_excluded_user_ids'
             ELSE '[]'::jsonb END
      ) AS excluded(user_id)
      WHERE excluded.user_id = account_users.user_id::text
    )
  SQL

  # The operator limit of every account, the way Ruby reads it (`to_i` of the text, a blank value is no value): how many
  # accounts of the organization have no finite limit and the sum of the finite ones. "No limit at all" is a missing
  # limit or the "no limit" number a plan writes (ChatwootApp.max_limit).
  LIMITS_SQL = <<~SQL.squish
    SELECT limits.organization_id,
           COUNT(*) FILTER (WHERE limits.agent_limit IS NULL OR limits.agent_limit >= :max) AS unlimited,
           COALESCE(SUM(limits.agent_limit) FILTER (WHERE limits.agent_limit < :max), 0) AS finite_sum
    FROM (
      SELECT accounts.organization_id,
             CASE
               WHEN NULLIF(btrim(accounts.custom_attributes ->> 'subscribed_quantity'), '') IS NOT NULL
                 THEN COALESCE(substring(btrim(accounts.custom_attributes ->> 'subscribed_quantity') FROM '^[+-]?[0-9]{1,12}')::bigint, 0)
               WHEN NULLIF(btrim(accounts.limits ->> 'agents'), '') IS NOT NULL
                 THEN COALESCE(substring(btrim(accounts.limits ->> 'agents') FROM '^[+-]?[0-9]{1,12}')::bigint, 0)
               ELSE :installation::bigint
             END AS agent_limit
      FROM accounts
      WHERE accounts.organization_id IN (:ids)
    ) AS limits
    GROUP BY limits.organization_id
  SQL

  def initialize(organizations)
    @ids = organizations.to_a.map(&:id)
    @accounts = Account.where(organization_id: @ids).group(:organization_id).count.transform_keys(&:to_i)
    @operators = operator_counts
    @channels = Inbox.joins(:account).where(accounts: { organization_id: @ids }).group('accounts.organization_id').count.transform_keys(&:to_i)
  end

  def for(organization)
    Row.new(
      accounts: @accounts.fetch(organization.id, 0),
      operators: @operators.fetch(organization.id, 0),
      channels: @channels.fetch(organization.id, 0)
    )
  end

  # The sum of the operator limits of the accounts of the organization, nil when some account has no finite limit (the
  # sum would mean nothing) and when it has no account. One grouped query, run the first time it is asked for.
  def operators_limit(organization)
    unlimited, finite_sum = limit_sums[organization.id]
    return if unlimited.nil? || unlimited.positive?

    finite_sum
  end

  private

  def operator_counts
    members = account_members.group('accounts.organization_id').count.transform_keys(&:to_i)
    return members unless Account.method_defined?(:limit_counter_excluded_user_ids) # only the enterprise account has the list

    excluded = account_members.where(EXCLUDED_MEMBER_SQL).group('accounts.organization_id').count.transform_keys(&:to_i)
    members.to_h { |organization_id, count| [organization_id, count - excluded.fetch(organization_id, 0)] }
  end

  def account_members
    AccountUser.joins(:account).where(accounts: { organization_id: @ids })
  end

  def limit_sums
    @limit_sums ||= begin
      installation = GlobalConfig.get('ACCOUNT_AGENTS_LIMIT')['ACCOUNT_AGENTS_LIMIT']
      sql = Account.sanitize_sql_array(
        [LIMITS_SQL, { ids: @ids, max: ChatwootApp.max_limit.to_i, installation: (installation.to_i if installation.present?) }]
      )
      Account.connection.select_rows(sql).to_h { |organization_id, unlimited, finite_sum| [organization_id.to_i, [unlimited.to_i, finite_sum.to_i]] }
    end
  end
end
