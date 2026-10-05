# Turns a phone number typed in any format into a condition on contacts.phone_number.
#
# 87072817060, +77072817060, 7 707 281 70 60, +7 (707) 281-70-60, 707 281 70 60 and 8-707-281-70-60 are the same
# number. Both the stored number and the typed text are reduced to digits, then:
#   - 10 digits or more: the LAST 10 digits are compared (the national number, so 8 / +7 / 7 / 0 and other country
#     codes do not matter);
#   - every length from 4 to 15 digits: the digits are looked for INSIDE the stored digits, so a number is found while
#     it is being typed and a fragment from the middle works too. A leading 7, 8 or 0 is a country code or a trunk
#     prefix that the stored number may not have in the same form, so the digits without it are looked for as well
#     (typing +7 707 281 70 6 finds a number stored as 87072817060 before the last digit is typed).
# 1-3 digits are not a phone search: they would match a large part of the table.
#
# The conditions are written exactly like the expression indexes of
# db/migrate/20261005190000_add_phone_digit_search_indexes_to_contacts.rb (regexp_replace(phone_number, '[^0-9]', '', 'g')
# and its right 10 digits), so PostgreSQL answers them from those indexes. The same rules are applied to the
# conversation list in app/javascript/dashboard/components/widgets/conversation/helpers/phoneSearch.js.
class Search::PhoneQuery
  MIN_DIGITS = 4
  MAX_DIGITS = 15 # E.164 limit
  NATIONAL_DIGITS = 10
  # Country code 7 (KZ, RU) and the trunk prefixes 8 and 0.
  PREFIXES = %w[7 8 0].freeze
  # Digits with the usual separators: spaces, dots, dashes of every kind, brackets and one leading plus.
  PHONE_INPUT = /\A\+?[\s\d().\-\u2010-\u2015\u2212]+\z/

  attr_reader :digits

  # Returns nil when the text is not a phone number (it has letters or other symbols, or the wrong number of digits).
  def self.parse(raw)
    text = Search::QueryText.clean(raw)
    return unless text.match?(PHONE_INPUT)

    digits = text.gsub(/\D/, '')
    return unless digits.length.between?(MIN_DIGITS, MAX_DIGITS)

    new(digits)
  end

  def initialize(digits)
    @digits = digits
  end

  def national?
    digits.length >= NATIONAL_DIGITS
  end

  def national_digits
    digits.last(NATIONAL_DIGITS)
  end

  # Digit strings that have to be contained in the stored number, the typed digits first.
  def fragments
    list = [digits]
    list << digits[1..] if PREFIXES.include?(digits[0]) && digits.length - 1 >= MIN_DIGITS
    list
  end

  def condition(table = Contact.arel_table)
    nodes = fragment_conditions(table)
    nodes.unshift(national_condition(table)) if national?
    Arel::Nodes::Grouping.new(nodes.reduce { |combined, node| combined.or(node) })
  end

  # The last 10 digits are the stored last 10 digits: answered by the (account_id, right 10 digits) index.
  def national_condition(table = Contact.arel_table)
    national_digits_expression(table).eq(quote(national_digits))
  end

  # The typed digits are inside the stored digits: answered by the trigram index on the digits.
  def fragment_conditions(table = Contact.arel_table)
    fragments.map { |fragment| digits_expression(table).matches("%#{fragment}%", nil, true) }
  end

  private

  def digits_expression(table)
    Arel::Nodes::NamedFunction.new('regexp_replace', [table[:phone_number], quote('[^0-9]'), quote(''), quote('g')])
  end

  def national_digits_expression(table)
    Arel::Nodes::NamedFunction.new('right', [digits_expression(table), quote(NATIONAL_DIGITS)])
  end

  def quote(value)
    Arel::Nodes.build_quoted(value)
  end
end
