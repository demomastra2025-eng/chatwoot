# Normalises free text typed by a person or produced by an LLM before it reaches a search query.
# The same folding (case, ё/е) is available as SQL so a column can be compared with the normalised text.
module Scheduling::SearchText
  MAX_LENGTH = 200
  MAX_TOKENS = 8
  LATIN_LOOKALIKES = {
    'a' => 'а', 'b' => 'в', 'c' => 'с', 'e' => 'е', 'h' => 'н', 'k' => 'к',
    'm' => 'м', 'o' => 'о', 'p' => 'р', 't' => 'т', 'x' => 'х', 'y' => 'у'
  }.freeze
  # A decimal number is one word ("1.5", also typed "1,5"); everything else is a run of letters and digits.
  WORD_PATTERN = /\d+(?:[.,]\d+)+|[[:alnum:]]+/
  # Case endings that make two forms of one word equal. Only words of five letters or more lose one, and at least three
  # letters stay, so a short word, a number or a code never loses its end. The endings of a plural genitive (-ов, -ев)
  # are left out on purpose: they would make the surname Петров the same word as the name Пётр.
  STEM_ENDINGS = %w[ого его ому ему ыми ими ой ей ий ый ая яя ое ее ые ие ую юю ом ем ах ях ам ям ы и а я у ю е о ь й]
                 .sort_by { |ending| -ending.length }.freeze
  MIN_STEMMED_WORD_LENGTH = 5
  MIN_STEM_LENGTH = 3
  # Words whose own letters carry the meaning ("после операции" is the opposite of "до операции").
  UNSTEMMED_WORDS = %w[после перед через между].freeze

  module_function

  def normalize(value, max_length: MAX_LENGTH)
    text = value.to_s.encode('UTF-8', invalid: :replace, undef: :replace, replace: '').scrub('')
    # Only canonical composition: the stored text is compared as it is (case and ё aside), so a compatibility fold
    # such as № -> No, ½ -> 1⁄2 or ™ -> TM would make a service name unfindable by its own name.
    text = text.unicode_normalize(:nfc).downcase.tr('ё', 'е')
    text = text.gsub(/[[:cntrl:]]/, ' ').squish
    text = text.first(max_length) if max_length
    text.split.map { |word| restore_cyrillic(word) }.join(' ')
  end

  # True when the text is longer than the normalised limit, so the normalised text has lost its tail.
  def truncated?(value)
    normalize(value, max_length: nil).length > MAX_LENGTH
  end

  def tokens(normalized_text)
    normalized_text.to_s.scan(/[[:alnum:]]+/).uniq.first(MAX_TOKENS)
  end

  # Every word of the text, without a limit and without a stop list: a short word, a preposition, a digit, a roman
  # numeral, a one-letter code and a decimal number all count. The retrieval tokens above may be capped to bound the SQL
  # work, the comparison of two texts may not.
  def words(normalized_text)
    normalized_text.to_s.scan(WORD_PATTERN).map { |word| word.tr(',', '.') }.uniq
  end

  def stem(word)
    return word if word.length < MIN_STEMMED_WORD_LENGTH || UNSTEMMED_WORDS.include?(word) || !word.match?(/\A[[:alpha:]]+\z/)

    ending = STEM_ENDINGS.find { |suffix| word.end_with?(suffix) && word.length - suffix.length >= MIN_STEM_LENGTH }
    ending ? word.delete_suffix(ending) : word
  end

  # Two normalised texts have the same words in any order. With stemmed: false the words must be letter for letter equal
  # (a person's name: Асланов and Асланова are two different names).
  def same_words?(left, right, stemmed: true)
    left_words = word_keys(left, stemmed)
    right_words = word_keys(right, stemmed)
    return left.to_s == right.to_s if left_words.empty? && right_words.empty?

    left_words == right_words
  end

  def word_keys(normalized_text, stemmed)
    words(normalized_text).to_set { |word| stemmed ? stem(word) : word }
  end

  def fold_sql(expression)
    "translate(LOWER(#{expression}), 'ё', 'е')"
  end

  # A Latin look-alike letter typed inside a Cyrillic token (for example "МRТ") is read as Cyrillic. The decision is
  # made per letters-and-digits token, so a real Latin abbreviation glued to a Cyrillic word by a hyphen or a slash
  # ("Анти-HCV", "ВИЧ/HIV", "Rh-фактор") stays as typed. A token that holds a Latin letter without a Cyrillic twin
  # (for example the "s" of "HBs") is left alone as well.
  def restore_cyrillic(word)
    word.gsub(/[[:alnum:]]+/) do |token|
      latin = token.scan(/[a-z]/)
      token.match?(/\p{Cyrillic}/) && latin.all? { |letter| LATIN_LOOKALIKES.key?(letter) } ? token.gsub(/[a-z]/, LATIN_LOOKALIKES) : token
    end
  end
end
