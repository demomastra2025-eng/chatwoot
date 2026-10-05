# Normalises free text typed by a person or produced by an LLM before it reaches a search query.
# The same folding (case, ё/е) is available as SQL so a column can be compared with the normalised text.
module Scheduling::SearchText
  MAX_LENGTH = 200
  MAX_TOKENS = 8
  LATIN_LOOKALIKES = {
    'a' => 'а', 'b' => 'в', 'c' => 'с', 'e' => 'е', 'h' => 'н', 'k' => 'к',
    'm' => 'м', 'o' => 'о', 'p' => 'р', 't' => 'т', 'x' => 'х', 'y' => 'у'
  }.freeze

  module_function

  def normalize(value)
    text = value.to_s.encode('UTF-8', invalid: :replace, undef: :replace, replace: '').scrub('')
    # Only canonical composition: the stored text is compared as it is (case and ё aside), so a compatibility fold
    # such as № -> No, ½ -> 1⁄2 or ™ -> TM would make a service name unfindable by its own name.
    text = text.unicode_normalize(:nfc).downcase.tr('ё', 'е')
    text = text.gsub(/[[:cntrl:]]/, ' ').squish.first(MAX_LENGTH)
    text.split.map { |word| restore_cyrillic(word) }.join(' ')
  end

  def tokens(normalized_text)
    normalized_text.to_s.scan(/[[:alnum:]]+/).uniq.first(MAX_TOKENS)
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
