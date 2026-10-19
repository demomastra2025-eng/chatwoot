# frozen_string_literal: true

# The search box in the header of the super admin: accounts (name, #id), users (e-mail, name) and organizations (name,
# legal name, БИН) in one go. Each group holds ten records and the total, so the page can offer «Показать все» when there
# are more (the filtered list of that kind).
#
# The text is matched as a part of the value without regard to case: both sides go through `lower()`, and the term is
# lowered by Ruby first, so «алатау» finds «Алатау» (Cyrillic letters have a case of their own). The characters that mean
# something to LIKE (`%`, `_`) are searched for as they are.
#
# The cost does not depend on how many records match: two queries per group (ten rows and the total) and one for what the
# rows show next to their names (the organizations of the accounts, the numbers of accounts of users and organizations).
#
#   result = SuperAdmin::GlobalSearch.new('алатау').call
#   result.groups.each { |group| group.key, group.records, group.total, group.more? }
class SuperAdmin::GlobalSearch
  PER_GROUP = 10
  MIN_LENGTH = 2
  MAX_LENGTH = 100
  # An account is found by its number too: «12» or «#12» (up to nine digits: a БИН of twelve is not a number of an account)
  ID_FORMAT = /\A#?(\d{1,9})\z/
  # A БИН is typed with or without spaces
  DIGITS_FORMAT = /\A[\d\s]+\z/

  # records: the first PER_GROUP of the group; extras: what the page shows next to a record, by record id
  Group = Struct.new(:key, :records, :total, :extras, keyword_init: true) do
    def more? = total > records.size
    def empty? = total.zero?
  end

  # state: :blank (nothing typed), :too_short or :found (the groups are filled; they may all be empty)
  Result = Struct.new(:term, :state, :groups, keyword_init: true) do
    def found? = state == :found
    def total = groups.sum(&:total)
    def nothing? = found? && total.zero?
  end

  GROUP_KEYS = %i[accounts users organizations].freeze

  def initialize(raw_term)
    @term = normalize(raw_term)
  end

  def call
    return Result.new(term: @term, state: :blank, groups: empty_groups) if @term.empty?
    return Result.new(term: @term, state: :too_short, groups: empty_groups) if too_short?

    Result.new(term: @term, state: :found, groups: [accounts_group, users_group, organizations_group])
  end

  private

  # Whitespace squeezed, Cyrillic letters composed (a «й» typed on a Mac can arrive as «и» + a mark), at most MAX_LENGTH
  def normalize(raw)
    raw.to_s.unicode_normalize(:nfc).squish.first(MAX_LENGTH)
  rescue ArgumentError, Encoding::CompatibilityError
    ''
  end

  def too_short?
    @term.length < MIN_LENGTH && !@term.match?(ID_FORMAT)
  end

  def empty_groups
    GROUP_KEYS.map { |key| Group.new(key: key, records: [], total: 0, extras: {}) }
  end

  def pattern
    @pattern ||= "%#{ApplicationRecord.sanitize_sql_like(@term.downcase)}%"
  end

  def account_id
    @account_id ||= @term[ID_FORMAT, 1]&.to_i
  end

  # ---------------------------------------------------------------- accounts

  def accounts_group
    scope = Account.where('LOWER(accounts.name) LIKE ?', pattern)
    scope = scope.or(Account.where(id: account_id)) if account_id
    records = scope.preload(:organization).order(account_order).limit(PER_GROUP).to_a
    Group.new(key: :accounts, records: records, total: scope.count, extras: {})
  end

  # The account with the number that was typed comes first, then the names A to Z
  def account_order
    names = [Arel.sql('LOWER(accounts.name)'), :id]
    return names unless account_id

    [Arel.sql(ApplicationRecord.sanitize_sql_array(['CASE WHEN accounts.id = ? THEN 0 ELSE 1 END', account_id]))] + names
  end

  # ------------------------------------------------------------------- users

  def users_group
    scope = User.where('LOWER(users.email) LIKE :pattern OR LOWER(users.name) LIKE :pattern', pattern: pattern)
    scope = scope.or(User.where(id: account_id)) if account_id
    records = scope.order(Arel.sql('LOWER(users.email)'), :id).limit(PER_GROUP).to_a
    Group.new(key: :users, records: records, total: scope.count, extras: account_counts(AccountUser, :user_id, records))
  end

  # ----------------------------------------------------------- organizations

  def organizations_group
    scope = Organization.where(organization_condition, pattern: pattern, bin: bin_pattern)
    records = scope.order(Arel.sql('LOWER(organizations.name)'), :id).limit(PER_GROUP).to_a
    Group.new(key: :organizations, records: records, total: scope.count, extras: account_counts(Account, :organization_id, records))
  end

  def organization_condition
    conditions = ['LOWER(organizations.name) LIKE :pattern', 'LOWER(organizations.legal_name) LIKE :pattern']
    conditions << 'organizations.bin LIKE :bin' if bin_pattern
    conditions.join(' OR ')
  end

  # The БИН holds digits only, so a term of digits (spaces allowed) is also looked for in it
  def bin_pattern
    return @bin_pattern if defined?(@bin_pattern)

    digits = @term.gsub(/\s+/, '') if @term.match?(DIGITS_FORMAT)
    @bin_pattern = ("%#{digits}%" if digits.present?)
  end

  # { record id => number of accounts it has }, for the records of one group, with one query
  def account_counts(model, column, records)
    return {} if records.empty?

    model.where(column => records.map(&:id)).group(column).count
  end
end
