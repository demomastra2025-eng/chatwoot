# Query-side transliteration only: stored names and indexed columns are never rewritten.
# Four fixed Latin spellings and bounded query-side regexps keep ambiguity linear,
# rather than enumerating every combination of Kazakh/Russian letters. These are spelling
# candidates, not identity equivalence: callers must keep all matching contacts for selection.
class Search::ContactNameQuery
  MAX_WORDS = 5
  MAX_LATIN_VARIANTS = 4
  NAME_COLUMNS = %i[name last_name middle_name].freeze
  CYRILLIC_TO_LATIN = {
    'а' => 'a', 'б' => 'b', 'в' => 'v', 'г' => 'g', 'д' => 'd', 'е' => 'e', 'ё' => 'yo', 'ж' => 'zh', 'з' => 'z',
    'и' => 'i', 'й' => 'y', 'к' => 'k', 'л' => 'l', 'м' => 'm', 'н' => 'n', 'о' => 'o', 'п' => 'p', 'р' => 'r',
    'с' => 's', 'т' => 't', 'у' => 'u', 'ф' => 'f', 'х' => 'kh', 'ц' => 'ts', 'ч' => 'ch', 'ш' => 'sh', 'щ' => 'shch',
    'ъ' => '', 'ы' => 'y', 'ь' => '', 'э' => 'e', 'ю' => 'yu', 'я' => 'ya',
    'ә' => 'a', 'ғ' => 'gh', 'қ' => 'q', 'ң' => 'ng', 'ө' => 'o', 'ұ' => 'u', 'ү' => 'u', 'һ' => 'h', 'і' => 'i'
  }.freeze
  LATIN_PROFILES = [
    {}, { 'ё' => 'e', 'й' => 'i' }, { 'ғ' => 'g', 'қ' => 'k', 'х' => 'h' },
    { 'ғ' => 'g', 'қ' => 'k', 'х' => 'h', 'ё' => 'e', 'й' => 'i' }
  ].map { |overrides| CYRILLIC_TO_LATIN.merge(overrides).freeze }.freeze
  LATIN_TO_CYRILLIC = {
    'shch' => 'щ', 'sch' => 'щ', 'zh' => 'ж', 'ch' => 'ч', 'sh' => 'ш', 'kh' => '[хһ]', 'gh' => '[гғ]', 'ng' => '(нг|ң)',
    'yo' => '[ьъ]?[её]', 'yu' => '[ьъ]?ю', 'ya' => '[ьъ]?я', 'ye' => '[ьъ]?[еёэ]', 'ts' => 'ц',
    'a' => '[аә]', 'b' => 'б', 'c' => 'ц', 'd' => 'д', 'e' => '[еёэ]', 'f' => 'ф', 'g' => '[гғ]', 'h' => '[хһ]',
    'i' => '[иій]', 'j' => 'ж', 'k' => '[кқ]', 'l' => 'л', 'm' => 'м', 'n' => 'н', 'o' => '[оө]', 'p' => 'п',
    'q' => 'қ', 'r' => 'р', 's' => 'с', 't' => 'т', 'u' => '[уұү]', 'v' => 'в', 'w' => 'в', 'x' => 'кс', 'y' => '[ый]', 'z' => 'з'
  }.freeze
  LATIN_TOKENS = Regexp.union(LATIN_TO_CYRILLIC.keys).freeze
  SPELLING_TOKENS = /#{LATIN_TOKENS}|./m

  attr_reader :text

  def initialize(raw_query)
    @text = Search::QueryText.clean(raw_query)
  end

  def apply(relation)
    relation.where(condition)
  end

  def condition(table = Contact.arel_table)
    nodes = part_conditions(table, text)
    nodes << all_words_condition(table) if words.size.between?(2, MAX_WORDS)
    Arel::Nodes::Grouping.new(nodes.reduce { |combined, node| combined.or(node) } || Arel::Nodes::False.new)
  end

  # Synthetic Playground uses the exact same spelling patterns, with no database access.
  def matches?(parts)
    values = parts.map { |part| part.to_s.downcase }
    return true if matches_part?(values, text)

    words.size.between?(2, MAX_WORDS) && words.all? { |word| matches_part?(values, word) }
  end

  private

  def words
    @words ||= text.split.first(MAX_WORDS + 1)
  end

  def literals(value)
    return [] if value.empty?

    ([value.downcase] + LATIN_PROFILES.first(MAX_LATIN_VARIANTS).map do |profile|
      value.downcase.each_char.map { |char| profile.fetch(char, char) }.join
    end).reject(&:empty?).uniq
  end

  def regexps(value)
    patterns = []
    if Search::QueryText.yo?(value)
      patterns << Search::QueryText.yo_regexp(value.downcase)
      patterns << value.downcase.each_char.map do |char|
        Search::QueryText.yo?(char) ? '(e|yo)' : Search::QueryText.yo_regexp(CYRILLIC_TO_LATIN.fetch(char, char))
      end.join
    end
    if value.match?(/[a-z]/i)
      # Escape every untouched character before inserting only our own, fixed regexp fragments.
      patterns << value.downcase.scan(SPELLING_TOKENS).map do |token|
        LATIN_TO_CYRILLIC.fetch(token) { Search::QueryText.yo_regexp(token) }
      end.join
    end
    patterns.uniq
  end

  def part_conditions(table, value)
    NAME_COLUMNS.flat_map do |column|
      literals(value).map { |literal| table[column].matches(Search::QueryText.like_pattern(literal), nil, false) } +
        regexps(value).map { |pattern| table[column].matches_regexp(pattern, false) }
    end
  end

  def all_words_condition(table)
    nodes = words.map { |word| Arel::Nodes::Grouping.new(part_conditions(table, word).reduce { |combined, node| combined.or(node) }) }
    Arel::Nodes::Grouping.new(nodes.reduce { |combined, node| combined.and(node) })
  end

  def matches_part?(values, value)
    values.any? do |part|
      literals(value).any? { |literal| part.include?(literal) } ||
        regexps(value).any? { |pattern| Regexp.new(pattern, Regexp::IGNORECASE).match?(part) }
    end
  end
end
