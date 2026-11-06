# The one place that decides which contacts a text typed into a search box finds. Used by the contacts search, the global
# search, the scheduling contacts search, the company contacts search and the conversation list search, so that all of
# them behave the same.
#
# The result is ADDITIVE: the long-standing matching stays exactly as it was (the text inside the name, e-mail, phone
# number or identifier, case-insensitive) and the following are OR-ed next to it:
#   - a phone number typed in any format finds the contact by its digits (see Search::PhoneQuery);
#   - "е" and "ё" are interchangeable in all three name parts;
#   - several words are looked for across first, last and middle names in any order;
#   - Cyrillic/Latin spelling candidates are searched in name parts only.
# Every arm uses a plain indexed column predicate: the pg_trgm indexes on the text fields and the phone digit indexes.
class Search::ContactQuery
  attr_reader :text

  # identifier_case_sensitive: the contacts search has always compared identifiers with LIKE (case-sensitive) because
  # identifiers such as external ids differ by case; every other search used ILIKE.
  def initialize(raw_query, identifier_case_sensitive: false, account_user: Current.account_user)
    @text = Search::QueryText.clean(raw_query)
    @identifier_case_sensitive = identifier_case_sensitive
    @account_user = account_user
  end

  def phone_query
    return @phone_query if defined?(@phone_query)

    @phone_query = Search::PhoneQuery.parse(text)
  end

  def apply(relation)
    relation.where(condition)
  end

  def condition(table = Contact.arel_table)
    Arel::Nodes::Grouping.new(arms(table).reduce { |combined, node| combined.or(node) })
  end

  private

  def arms(table)
    nodes = text_arms(table)
    nodes << Search::ContactNameQuery.new(text).condition(table)
    nodes << phone_query.condition(table) if phone_query
    nodes << contact_phones_arm(table) if ContactPhone.table_exists?
    nodes
  end

  def contact_phones_arm(table)
    cp = ContactPhone.arel_table
    phone_match = cp[:phone_number].matches(Search::QueryText.like_pattern(text), nil, false)
    phone_match = phone_match.or(phone_query.condition(cp)) if phone_query
    subquery = cp.project(Arel.sql('1'))
                 .where(
                   cp[:contact_id].eq(table[:id])
                     .and(cp[:account_id].eq(table[:account_id]))
                     .and(Arel::Nodes::Grouping.new(phone_match))
                 )
    Arel::Nodes::Exists.new(subquery)
  end

  # Name predicates live in ContactNameQuery; other fields keep their original, literal semantics.
  def text_arms(table)
    pattern = Search::QueryText.like_pattern(text)
    [
      table[:email].matches(pattern, nil, false),
      table[:phone_number].matches(pattern, nil, false),
      identifier_arm(table, pattern)
    ]
  end

  def identifier_arm(table, pattern)
    arm = table[:identifier].matches(pattern, nil, @identifier_case_sensitive)
    return arm if Contacts::IinPrivacy.can_view_iin?(account_user: @account_user)

    quoted_table = ActiveRecord::Base.connection.quote_table_name(table.name)
    non_iin_guard = Arel.sql("regexp_replace(COALESCE(#{quoted_table}.identifier, ''), '[[:space:]-]', '', 'g') !~ '^[0-9]{12}$'")
    Arel::Nodes::Grouping.new(arm.and(non_iin_guard))
  end
end
