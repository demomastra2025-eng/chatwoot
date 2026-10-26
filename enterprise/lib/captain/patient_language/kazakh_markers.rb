# frozen_string_literal: true

# Kazakh in the words of a text, read from letters and words alone, with no model. The decision model of Captain::PatientLanguageDetector
# counts the meaningful words of the last five patient messages, and a Kazakh message with Russian loanwords, or a turn of short Kazakh
# messages after older Russian ones, came out Russian: in the suggestion eval of 26.10 three Kazakh turns of Әлия and a real PROD turn
# (a Kazakh sentence with one Russian word) got a Russian draft. A text that this module reads as Kazakh is Kazakh, even when it has
# Russian loanwords in it; any other text is left to the model.
#
# A word is read as Kazakh by a letter that only Kazakh has (ә ғ қ ң ө ұ ү һ і) in a lowercase word (strong), or by a word that is Kazakh
# however it is typed (CLEAR_WORDS: patients write on a Russian keyboard without the special letters), or by a capitalized word at the
# start of a sentence that has such a letter (weak: it may be a name, «Әлия принимает?»). Words that are names (capitalized in the
# middle of a sentence) and abbreviations (УЗИ, ИИН) are not counted at all. A text is Kazakh when it has a strong word and, of its
# counted words, at least two in five are Kazakh (a very short text: at least half); a text typed without the special letters is
# Kazakh when it has at least three clear words and they are half of the counted words. One Kazakh name or word in a Russian sentence
# is not enough.
module Captain::PatientLanguage::KazakhMarkers
  SPECIAL_LETTERS = /[әғқңөұүһі]/
  # Words of Kazakh and of no Russian, in the plain Russian letters.
  CLEAR_WORDS = %w[
    рахмет рахмат салем саламатсыз салеметсиз кандай канша болады болмайды болама бола болсын керек емес жок жаксы келген келди келем
    келемин барамын кешке ертен бугин уакыт кашан кайда калай неше деп дегем еди жане бирак себеби кейин кеше бурын дейин осы мына мен
    сиз биз жазылу жазылам жазылайын жазып келе алмаймын алмайды алмаймыз ма ме ба бе ге
  ].to_set.freeze
  # A text of at most this many counted words is Kazakh when at least half of them are.
  SHORT_TEXT_WORDS = 3
  # A text with no special letter needs this many clear words (see CLEAR_WORDS).
  TYPED_PLAIN_WORDS = 3

  module_function

  def kazakh?(text)
    counts = count(text.to_s)
    marked = counts[:strong] + counts[:weak]
    total = counts[:total]
    return marked >= TYPED_PLAIN_WORDS && marked * 2 >= total if counts[:strong].zero?

    (marked >= 2 && marked * 5 >= total * 2) || (total <= SHORT_TEXT_WORDS && marked * 2 >= total)
  end

  # { strong:, weak:, total: } of the words of the text.
  def count(text)
    counts = { strong: 0, weak: 0, total: 0 }
    text.to_enum(:scan, /[[:alpha:]]{2,}/).each do
      match = Regexp.last_match
      kind = word_kind(match[0], sentence_start?(text, match.begin(0)))
      next if kind == :skipped

      counts[:total] += 1
      counts[kind] += 1 if kind != :plain
    end
    counts
  end

  # :skipped (a name or an abbreviation), :strong, :weak or :plain.
  def word_kind(word, sentence_start)
    return :skipped if word == word.upcase

    capital = word[0] != word[0].downcase
    return :skipped if capital && !sentence_start

    lower = word.downcase
    return capital ? :weak : :strong if lower.match?(SPECIAL_LETTERS)

    CLEAR_WORDS.include?(lower) ? :weak : :plain
  end

  # The word opens the text or a sentence (after . ! ? … or a new line, with quotes, brackets or dashes in between).
  def sentence_start?(text, index)
    text[0...index].match?(/(?:\A|[.!?…\n])[[:space:]«"'(\[—–-]*\z/)
  end
end
