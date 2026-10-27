# frozen_string_literal: true

# A time of a draft can be found among the free times of the run (Captain::ReplySuggestion::DraftTimes) and still be under the wrong
# name: in the suggestion eval of 27.10 a draft gave the free times of one gynecologist under the name of the other. This reads the
# draft sentence by sentence: a time that stands under the name of a specialist must be one that the slot reads of the run list for that
# specialist (Captain::ReplySuggestion::SearchedSlots#specialists); a time that they list for other specialists only is named to the
# manager with the name it was given (the draft itself is never changed: the manager decides). Left alone: a sentence without a name, a
# name that fits two specialists, a time on the side of the sentence that has no name, a time that is a bound, and a time that no slot
# read lists (DraftTimes names it).
#
# Where a time stands: a sentence that starts with a name lists the times under it («У Ивановой 10:00 и 11:00, у Петровой 14:00»), so a
# time stands under the nearest name before it; a sentence that starts with a time names the specialist after it («в 10:30 — Иванова»),
# so a time stands under the nearest name after it.
module Captain::ReplySuggestion::DraftSpecialists
  # A word of a name carries it from this many letters; a case form is cut off so «Князова» is found in «Князовой».
  MIN_NAME_WORD = 4
  WORD = /[[:alpha:]]{#{MIN_NAME_WORD},}/
  # A line, or the end of a sentence (the full stop after an initial or a capital, «Ж.» or «УЗИ.», does not end one).
  SENTENCE_END = /\n+|(?<=[[:lower:][:digit:])»"'][.!?])[[:space:]]+/

  module_function

  # [{ 'name' => 'Князова Жанат', 'time' => '09:00' }] in the order of the draft; empty when the run read no list of times.
  def misattributed(draft:, context:)
    people = named_specialists(context)
    listed = people.values.flat_map { |person| person[:times] }.to_set
    return [] if listed.empty?

    stems = people.transform_values { |person| name_stems(person[:name]) }
    sentences_of(draft).flat_map { |sentence| sentence_findings(sentence, people, stems, listed) }.uniq
  end

  # { resource_id => { name:, times: } } of the specialists the reads of the run name.
  def named_specialists(context)
    Captain::ReplySuggestion::SearchedSlots.new(context.to_h).specialists.select { |_id, person| person[:name].present? }
  end

  def sentences_of(draft)
    draft.to_s.split(SENTENCE_END).map(&:strip).compact_blank
  end

  def sentence_findings(sentence, people, stems, listed)
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
  def mentions(sentence, people, stems)
    sentence.to_enum(:scan, WORD).filter_map do
      match = Regexp.last_match
      word = match[0].downcase
      ids = people.keys.select { |id| stems[id].any? { |stem| word.start_with?(stem) } }
      [match.begin(0), ids.first] if ids.one?
    end
  end

  # The resource_id of the nearest name before the time (name_first) or after it; nil when there is none on that side.
  def standing_under(names, position, name_first)
    side = name_first ? names.select { |at, _id| at < position }.max_by(&:first) : names.select { |at, _id| at > position }.min_by(&:first)
    side&.last
  end

  def name_stems(name)
    name.to_s.downcase.scan(WORD).map { |word| word.length > 5 ? word[0, word.length - 2] : word[0, [word.length - 1, MIN_NAME_WORD].max] }
  end
end
