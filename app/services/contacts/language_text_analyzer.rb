class Contacts::LanguageTextAnalyzer
  Lex = Contacts::LanguageLexicon

  def self.analyze(texts)
    weights = Hash.new(0.0)
    last_seen = {}
    step = 0

    Array(texts).each do |raw_text|
      sanitize_text(raw_text).split(/[.!?…;\n]+/).each do |clause|
        clause_weights = score_clause(clause)
        next if clause_weights.empty?

        step += 1
        record_clause_weights(clause_weights, weights, last_seen, step)
      end
    end

    normalize_weights(weights, last_seen)
  end

  def self.record_clause_weights(clause_weights, weights, last_seen, step)
    clause_weights.each do |code, weight|
      next unless weight.positive?

      weights[code] += weight
      last_seen[code] = step
    end
  end

  def self.normalize_weights(weights, last_seen = {})
    positive = weights.select { |_code, weight| weight.to_f.positive? }
    total = positive.values.sum.to_f
    return [] unless total.positive?

    kept = filter_significant_weights(positive, total)
    rows = build_percentage_rows(kept, last_seen)
    distribute_remainder!(rows, last_seen)
    format_percentage_rows(rows, last_seen)
  end

  def self.filter_significant_weights(positive, total)
    kept = positive.select { |_code, weight| ((weight.to_f / total) * 100.0) >= 5.0 }
    kept.empty? ? positive : kept
  end

  def self.build_percentage_rows(kept, last_seen)
    kept_total = kept.values.sum.to_f
    kept.sort_by { |code, weight| [-weight.to_f, -(last_seen[code] || 0), code.to_s] }.map do |code, weight|
      exact = (weight.to_f / kept_total) * 100.0
      pct = exact.floor
      { code: code.to_s, exact: exact, pct: pct, rem: exact - pct }
    end
  end

  def self.distribute_remainder!(rows, last_seen)
    leftover = [100 - rows.sum { |row| row[:pct] }, 0].max
    rows.sort_by { |row| [-row[:rem], -row[:exact], -(last_seen[row[:code]] || 0), row[:code]] }
        .first(leftover)
        .each { |row| row[:pct] += 1 }
  end

  def self.format_percentage_rows(rows, last_seen)
    rows.select { |row| row[:pct].positive? }
        .sort_by { |row| [-row[:pct], -(last_seen[row[:code]] || 0), row[:code]] }
        .map { |row| { 'code' => row[:code], 'percentage' => row[:pct] } }
  end

  def self.sanitize_text(raw_text)
    raw_text.to_s
            .gsub(%r{https?://\S+|www\.\S+}i, ' ')
            .gsub(/\S+@\S+\.\S+/, ' ')
            .gsub(/\{\{[^}]*\}\}/, ' ')
            .strip
  end

  def self.score_clause(clause)
    raw_tokens = extract_clause_tokens(clause)
    return {} if raw_tokens.empty?

    all_caps = all_caps_clause?(raw_tokens)
    tallies = Hash.new(0)
    raw_tokens.each do |word, at_start|
      kind = classify_word(word, at_start, all_caps)
      tallies[kind] += 1 if kind != :skip
    end
    resolve_clause_weights(tallies)
  end

  def self.extract_clause_tokens(clause)
    tokens = []
    clause.to_enum(:scan, /[[:alpha:]'-]{2,}/).each do
      match = Regexp.last_match
      word = match[0].gsub(/\A['-]+|['-]+\z/, '')
      tokens << [word, clause_start?(clause, match.begin(0))] if word.length >= 2
    end
    tokens
  end

  def self.clause_start?(clause, index)
    clause[0...index].match?(/\A[[:space:]«"'(\[—–-]*\z/)
  end

  def self.all_caps_clause?(raw_tokens)
    words = raw_tokens.map(&:first)
    words.size >= 2 && words.count { |word| uppercase_word?(word) } * 5 >= words.size * 4
  end

  def self.uppercase_word?(word)
    word == word.upcase && word != word.downcase
  end

  def self.classify_word(word, at_start, all_caps)
    return :skip if skip_surface_word?(word, at_start, all_caps)

    lower = word.downcase
    return :skip if Lex::NEUTRAL_FILLERS.include?(lower)

    Lex.detect_non_cyrillic_script(lower) || classify_cyrillic_word(lower, capitalized_word?(word) && !all_caps)
  end

  def self.skip_surface_word?(word, at_start, all_caps)
    return true if Lex::SHARED_ACRONYMS.include?(word.upcase)
    return true if !all_caps && uppercase_word?(word) && word.length <= 6

    !all_caps && !at_start && capitalized_word?(word)
  end

  def self.capitalized_word?(word)
    word[0] != word[0].downcase
  end

  def self.classify_cyrillic_word(lower, capitalized_start)
    return :skip unless lower.match?(/\p{Cyrillic}/)
    return classify_kazakh_letter_word(lower, capitalized_start) if lower.match?(Lex::KAZAKH_SPECIAL_LETTERS)
    return :kk_plain if Lex.kazakh_plain_word?(lower)
    return :cyr_medical if Lex::SHARED_MEDICAL_LOANWORDS.include?(lower)
    return :ru_marked if Lex.russian_marked_word?(lower)

    capitalized_start ? :ru_weak : :ru_plain
  end

  def self.classify_kazakh_letter_word(lower, capitalized_start)
    !capitalized_start || Lex.kazakh_known_stem?(lower) ? :kk_strong : :kk_weak
  end

  def self.resolve_clause_weights(tallies)
    other_langs = extract_other_language_counts(tallies)
    cyr_shares, cyr_count = resolve_cyrillic_counts(tallies)
    total = other_langs.values.sum + cyr_count
    return {} unless total.positive?

    combine_clause_shares(other_langs, cyr_shares, cyr_count, total)
  end

  def self.extract_other_language_counts(tallies)
    tallies.each_with_object({}) do |(key, count), acc|
      acc[key.to_s.delete_prefix('lang_')] = count if key.to_s.start_with?('lang_')
    end
  end

  def self.combine_clause_shares(other_langs, cyr_shares, cyr_count, total)
    weight = total.clamp(1, 6).to_f
    return { 'kk' => weight } if cyr_shares == { 'kk' => 1.0 } && cyr_count >= 3 && other_langs == { 'en' => 1 }

    result = Hash.new(0.0)
    other_langs.each { |code, count| result[code] += weight * (count.to_f / total) }
    cyr_shares.each { |code, share| result[code] += weight * (cyr_count.to_f / total) * share }
    result
  end

  def self.resolve_cyrillic_counts(tallies)
    kk_eff = effective_kazakh_count(tallies)
    ru_eff = effective_russian_count(tallies, kk_eff)
    neutral = tallies[:cyr_medical] + tallies[:ru_plain] + tallies[:ru_weak]
    return [{}, 0] if kk_eff.zero? && ru_eff.zero?
    return [{ 'kk' => 1.0 }, kk_eff + neutral] if tallies[:ru_marked].zero? && kk_eff.positive?
    return [{ 'ru' => 1.0 }, ru_eff + tallies[:cyr_medical]] if kk_eff.zero?

    split_mixed_cyrillic(kk_eff, tallies[:kk_strong], tallies[:ru_marked], neutral)
  end

  def self.effective_kazakh_count(tallies)
    definite = tallies[:kk_strong] + tallies[:kk_plain]
    definite.positive? ? definite + tallies[:kk_weak] : 0
  end

  def self.effective_russian_count(tallies, kk_eff)
    definite = tallies[:ru_marked] + (kk_eff.zero? ? tallies[:ru_plain] : 0)
    definite.positive? ? definite + tallies[:ru_weak] : 0
  end

  def self.split_mixed_cyrillic(kk_eff, kk_strong, ru_marked, neutral_count)
    total = kk_eff + ru_marked + neutral_count
    return [{ 'kk' => 1.0 }, total] if kk_eff >= ru_marked * 3 && ru_marked == 1
    return [{ 'ru' => 1.0 }, total] if ru_marked >= kk_eff * 3 && kk_strong.zero?

    kk_share = kk_eff.to_f / (kk_eff + ru_marked)
    [{ 'kk' => kk_share, 'ru' => 1.0 - kk_share }, total]
  end
end
