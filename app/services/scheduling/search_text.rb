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
    text = text.unicode_normalize(:nfkc).downcase.tr('ё', 'е')
    text = text.gsub(/[[:cntrl:]]/, ' ').squish.first(MAX_LENGTH)
    text.split.map { |word| restore_cyrillic(word) }.join(' ')
  end

  def tokens(normalized_text)
    normalized_text.to_s.scan(/[[:alnum:]]+/).uniq.first(MAX_TOKENS)
  end

  def fold_sql(expression)
    "translate(LOWER(#{expression}), 'ё', 'е')"
  end

  # A word typed with a Latin letter inside a Cyrillic word (for example "МRТ") is read as Cyrillic.
  def restore_cyrillic(word)
    return word unless word.match?(/\p{Cyrillic}/)

    word.gsub(/[abcehkmoptxy]/, LATIN_LOOKALIKES)
  end
end
