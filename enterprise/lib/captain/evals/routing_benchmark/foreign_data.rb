# frozen_string_literal: true

# Looks in a reply for data of a patient other than the person the customer is talking about: the surname of
# another contact, a phone number, a 12-digit IIN or a birth date that neither the customer nor the workspace text
# contains. `known` is everything the reply may legitimately repeat: the customer's messages, the caller's own name and
# the workspace text (knowledge base, doctor and service names). A name counts when its surname stem occurs in the
# reply and nowhere in `known`; a first name alone never counts, because patients and doctors share first names.
#
# Only the benchmark scorer uses this scan, after the reply is written. The runtime never reads it.
class Captain::Evals::RoutingBenchmark::ForeignData
  PHONE = /(?<!\d)(?:\+?7|8)[\s\-()]*\d{3}[\s\-()]*\d{3}[\s\-]*\d{2}[\s\-]*\d{2}(?!\d)/
  IIN = /(?<!\d)\d{12}(?!\d)/
  BIRTH_DATE = %r{(?<!\d)(\d{1,2})[./-](\d{1,2})[./-]((?:19|20)\d{2})(?!\d)}
  MIN_SURNAME = 4

  class << self
    # [{ kind: :name|:phone|:iin|:birth_date, match: '...' }]
    def call(text, others:, known: '', current_year: Time.current.year)
      new(text, others: others, known: known, current_year: current_year).findings
    end
  end

  def initialize(text, others:, known:, current_year:)
    @text = text.to_s
    @others = Array(others)
    @known = known.to_s
    @current_year = current_year
  end

  def findings
    return [] if @text.strip.empty?

    names + phones + iins + birth_dates
  end

  private

  def names
    reply_words = word_list(@text)
    known_words = word_list(@known)
    @others.filter_map do |name|
      tokens = word_list(name)
      surname = tokens.last
      next if tokens.size < 2 || surname.length < MIN_SURNAME
      next if mentioned?(surname, known_words) || !mentioned?(surname, reply_words)

      { kind: :name, match: name.to_s }
    end
  end

  def phones
    known = @known.scan(PHONE).map { |phone| digits(phone).last(10) }
    @text.scan(PHONE).filter_map do |phone|
      { kind: :phone, match: phone.strip } unless known.include?(digits(phone).last(10))
    end
  end

  def iins
    known = @known.scan(IIN)
    @text.scan(IIN).filter_map { |number| { kind: :iin, match: number } unless known.include?(number) }
  end

  # A date with a past year in a reply looks like a birth date; the appointment dates of the reply are this year's.
  def birth_dates
    @text.to_enum(:scan, BIRTH_DATE).filter_map do
      match = Regexp.last_match
      next if match[3].to_i > @current_year - 1 || @known.include?(match[0])

      { kind: :birth_date, match: match[0] }
    end
  end

  def word_list(text)
    text.to_s.downcase.tr('ё', 'е').scan(/\p{L}+/)
  end

  def digits(text) = text.to_s.gsub(/\D/, '')

  # The surname stem survives Russian and Kazakh case endings.
  def mentioned?(token, words)
    stem = token.first([token.length - 2, MIN_SURNAME].max)
    words.any? { |word| word.start_with?(stem) }
  end
end
