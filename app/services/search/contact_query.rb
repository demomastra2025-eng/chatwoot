# The one place that decides which contacts a text typed into a search box finds. Used by the contacts search, the global
# search, the scheduling contacts search, the company contacts search and the conversation list search, so that all of
# them behave the same.
#
# The result is ADDITIVE: the long-standing matching stays exactly as it was (the text inside the name, e-mail, phone
# number or identifier, case-insensitive) and three things are OR-ed next to it:
#   - a phone number typed in any format finds the contact by its digits (see Search::PhoneQuery);
#   - "е" and "ё" are interchangeable in names (Семён / Семен, Киселёв / Киселев, also with both letters in one name);
#   - several words are looked for in the name in any order ("Иванов Иван" finds "Иван Иванов").
# Every arm is answered from an index: the pg_trgm index on name/e-mail/phone/identifier, the phone digit indexes.
class Search::ContactQuery
  MAX_WORDS = 5

  attr_reader :text

  # identifier_case_sensitive: the contacts search has always compared identifiers with LIKE (case-sensitive) because
  # identifiers such as external ids differ by case; every other search used ILIKE.
  def initialize(raw_query, identifier_case_sensitive: false)
    @text = Search::QueryText.clean(raw_query)
    @identifier_case_sensitive = identifier_case_sensitive
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
    nodes << name_matches(table, text) if Search::QueryText.yo?(text)
    nodes << all_words_in_name(table) if words.size > 1
    nodes << phone_query.condition(table) if phone_query
    nodes
  end

  # The text inside the name, e-mail, phone number or identifier, as it has always been matched.
  def text_arms(table)
    pattern = Search::QueryText.like_pattern(text)
    [
      table[:name].matches(pattern, nil, false),
      table[:email].matches(pattern, nil, false),
      table[:phone_number].matches(pattern, nil, false),
      table[:identifier].matches(pattern, nil, @identifier_case_sensitive)
    ]
  end

  def words
    @words ||= text.split.first(MAX_WORDS)
  end

  def all_words_in_name(table)
    Arel::Nodes::Grouping.new(words.map { |word| name_matches(table, word) }.reduce { |combined, node| combined.and(node) })
  end

  # "е" and "ё" are the same letter: a text with either is looked for as a regular expression that accepts both.
  def name_matches(table, value)
    return table[:name].matches_regexp(Search::QueryText.yo_regexp(value), false) if Search::QueryText.yo?(value)

    table[:name].matches(Search::QueryText.like_pattern(value), nil, false)
  end
end
