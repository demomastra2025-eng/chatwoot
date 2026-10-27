# frozen_string_literal: true

# A time of a draft can be found among the free times of the run (Captain::ReplySuggestion::DraftTimes) and still be under the wrong
# name: in the suggestion eval of 27.10 a draft gave the free times of one gynecologist under the name of the other. This reads the
# draft sentence by sentence: a time that stands under the name of a specialist must be one that the slot reads of the run list for that
# specialist (Captain::ReplySuggestion::SearchedSlots#specialists); a time that they list for other specialists only is named to the
# manager with the name it was given (the draft itself is never changed: the manager decides). Left alone: a sentence without a name, a
# name that fits two specialists, a time on the side of the sentence that has no name, a time that is a bound, and a time that no slot
# read lists (DraftTimes names it).
#
# Where a time stands: a clause that starts with a name lists the times under it («У Ивановой 10:00 и 11:00, у Петровой 14:00»), so a
# time stands under the nearest name before it; a clause that starts with a time names the specialist after it («в 10:30 — Иванова»),
# so a time stands under the nearest name after it. A sentence is read clause by clause, a clause ends at «а», «но», «однако» or «зато»
# («Иванова в 10:00, а 14:00 у Петровой» is two clauses, each with its own order). Also left alone: a name the draft addresses the patient
# with («Мария, есть 10:00 у Ивановой»), and the time of a booking the patient has, which the draft names without offering it.
#
# A word is the name of a specialist when it is a form of one of the words of her name, read as the search of specialists reads it
# (Scheduling::SearchText: case, ё and the Kazakh letters folded, the case ending cut off): «Князовой» is «Князова», «Жанаргүл» is
# «Жанаргуль», and «Жанаргүл» is never «Жанат». The same word never names two specialists. The suggestion eval of 27.10 flagged three
# drafts, all by mistake: a Kazakh letter in a name (the shorter name of another doctor matched its first letters), a sentence that went
# on after «₸.», and the initial «А.» of a doctor read as the conjunction «а».
module Captain::ReplySuggestion::DraftSpecialists
  # A word of a name counts from this many letters (shorter words are initials, particles and common words).
  MIN_NAME_WORD = 4
  WORD = /[[:alpha:]]{#{MIN_NAME_WORD},}/
  # A line, or the end of a sentence: an exclamation or a question mark, or a full stop that no capital letter stands before (the full
  # stop after an initial or a capital, «Ж.» or «УЗИ.», does not end one; the one after a digit, a sign like «₸» or a lower case letter does).
  SENTENCE_END = /\n+|(?:(?<![[:upper:]])\.|[!?])[[:space:]]+/
  # Where a sentence turns to another specialist or to another time: «а», «но», «однако», «зато», in lower case (the initial «А.» of a
  # doctor is no conjunction, and a capital word starts a sentence, which is split before). A dash or a semicolon does not end a clause:
  # «Князова Жанат — 11:00, 12:30; Турешева Акбаян — 09:00» lists the times under the names before them.
  CLAUSE_END = /(?<![[:alpha:]])(?:а|но|однако|зато)(?![[:alpha:]])/
  # The words before a name that address the patient by it («Добрый день, Айгерим», «Здравствуйте, Мария»).
  GREETING = /\A(?:(?:добр\p{L}+[[:space:]]+\p{L}+|здравствуйте|привет|сәлеметсіз бе|сәлем)[,!]?[[:space:]]+)?\z/i

  module_function

  # [{ 'name' => 'Князова Жанат', 'time' => '09:00' }] in the order of the draft; empty when the run read no list of times.
  def misattributed(draft:, context:)
    people = named_specialists(context)
    listed = people.values.flat_map { |person| person[:times] }.to_set
    return [] if listed.empty?

    stems = people.transform_values { |person| name_stems(person[:name]) }
    booked = Captain::ReplySuggestion::DraftTimes.booked_times(context)
    clauses_of(draft).flat_map { |clause| clause_findings(clause, people, stems, listed - booked) }.uniq
  end

  # { resource_id => { name:, times: } } of the specialists the reads of the run name.
  def named_specialists(context)
    Captain::ReplySuggestion::SearchedSlots.new(context.to_h).specialists.select { |_id, person| person[:name].present? }
  end

  def clauses_of(draft)
    draft.to_s.split(SENTENCE_END).flat_map { |sentence| sentence.split(CLAUSE_END) }.map(&:strip).compact_blank
  end

  def clause_findings(sentence, people, stems, listed)
    names = mentions(sentence, people, stems)
    times = Captain::ReplySuggestion::DraftTimes.offered_time_matches(sentence)
    return [] if names.empty? || times.empty?

    name_first = names.first.first < times.first.first
    times.filter_map do |position, time|
      person = people[standing_under(names, position, name_first)]
      finding(person, time) if person && person[:times].exclude?(time) && listed.include?(time)
    end
  end

  def finding(person, time)
    { 'name' => person[:name], 'time' => time }
  end

  # [position, resource_id] of every word of the sentence that is the name of exactly one specialist, in the order of the sentence.
  # A name that addresses the patient («Мария, есть 10:00») names nobody.
  def mentions(sentence, people, stems)
    sentence.to_enum(:scan, WORD).filter_map do
      match = Regexp.last_match
      next if addressing?(sentence, match)

      stem = stem_of(match[0])
      ids = people.keys.select { |id| stems[id].include?(stem) }
      [match.begin(0), ids.first] if ids.one?
    end
  end

  # The word is the first of the sentence, or comes after a greeting, and a comma or an exclamation mark follows it. The first word of
  # the sentence that a time follows at once («Иванова, 10:00») lists that time under it, it does not address anybody.
  def addressing?(sentence, match)
    rest = sentence[match.end(0)..].to_s
    before = sentence[0...match.begin(0)]
    return false unless rest.match?(/\A[,!]/) && before.match?(GREETING)

    before.strip.present? || !rest.match?(/\A[,!][[:space:]]*(?:в |на |с )?\d/i)
  end

  # The resource_id of the nearest name before the time (name_first) or after it; nil when there is none on that side.
  def standing_under(names, position, name_first)
    side = name_first ? names.select { |at, _id| at < position }.max_by(&:first) : names.select { |at, _id| at > position }.min_by(&:first)
    side&.last
  end

  # The stems of the words of a name ("Князова Жанат" -> ["князов", "жанат"]).
  def name_stems(name)
    Scheduling::SearchText.normalize(name).scan(WORD).map { |word| Scheduling::SearchText.stem(word) }
  end

  # The stem of a word of the draft, read as the stems of a name are: the same word in another case, or with a Kazakh letter, is the same.
  def stem_of(word)
    Scheduling::SearchText.stem(Scheduling::SearchText.normalize(word))
  end
end
