# frozen_string_literal: true

# Finds past-tense claims that an operation was done in a customer-facing reply, in Russian, Kazakh and the
# English markers of the first harness version. Two shapes are recognised:
#   - an action claim ("записала вас", "перенесла", "жазып қойдым"), true only after a matching successful
#     mutation, and
#   - a state claim ("вы записаны", "запись отменена", "жазылдыңыз"), which is also true when the same turn read
#     the appointment back with a successful lookup tool.
# Questions, offers, futures, infinitives ("перенести", "перенесём", "запишу"), hypotheticals ("перенесла бы"),
# negations ("не записала", "запись не перенесена"), indirect questions ("записаны ли вы", "жазылдыңыз ба") and
# claims about stored data ("записала ваш номер") are not claims. #kinds returns the claim kinds found;
# KIND_TOOLS lists the successful tool calls that support each.
#
# Only the benchmark scorer uses this detector, to score replies after the fact. The runtime never reads it: no reply
# is filtered or rewritten by it.
class Captain::Evals::RoutingBenchmark::SuccessClaims
  def self.words(*stems) = /(?<!\p{L})(?:#{stems.join('|')})(?!\p{L})/i

  PATTERNS = {
    book: words('записал(?:а|и)?', 'забронировал(?:а|и)?', 'booked', 'жазып\s+қой(?:дым|дық)', 'жаз(?:дым|дық)', 'тірке(?:дім|дік)',
                'броньда(?:дым|дық)'),
    book_state: words('записан(?:а|о|ы)?', 'забронирован(?:а|о|ы)?', 'жазылдың(?:ыз(?:дар)?|дар)', 'жазылды', 'тіркелдіңіз', 'тіркелді',
                      'броньдалды'),
    reschedule: words('перен[её]с(?:ла|ли|ло)?', 'перезаписал(?:а|и)?', 'rescheduled', 'ауыстыр(?:дым|дық)', 'ауыстырып\s+қойдым',
                      'көшірдім'),
    reschedule_state: words('перенес[её]н(?:а|о|ы)?', 'перезаписан(?:а|о|ы)?', 'ауыстырылды', 'көшірілді'),
    cancel: words('отменил(?:а|и)?', 'аннулировал(?:а|и)?', 'удалил(?:а|и)?', 'cancell?ed', 'жой(?:дым|дық)', 'бас\s+тарттым',
                  'болдырмадым', 'тоқтаттым'),
    cancel_state: words('отмен[её]н(?:а|о|ы)?', 'аннулирован(?:а|о|ы)?', 'удален(?:а|о|ы)?', 'жойылды', 'тоқтатылды'),
    create: words('создал(?:а|и)?', 'оформил(?:а|и)?', 'created', 'жаса(?:дым|дық)', 'құрдым', 'рәсімде(?:дім|дік)'),
    create_state: words('создан(?:а|о|ы)?', 'оформлен(?:а|о|ы)?', 'жасалды', 'құрылды', 'рәсімделді')
  }.freeze

  LOOKUP_TOOLS = %w[list_my_appointments get_appointment search_appointments].freeze
  # Successful tool calls that make a claim of the kind true.
  KIND_TOOLS = {
    book: %w[create_appointment],
    book_state: %w[create_appointment update_appointment] + LOOKUP_TOOLS,
    reschedule: %w[update_appointment],
    reschedule_state: %w[update_appointment],
    cancel: %w[cancel_appointment],
    cancel_state: %w[cancel_appointment] + LOOKUP_TOOLS,
    create: %w[create_appointment create_deal create_task create_company],
    create_state: %w[create_appointment create_deal create_task create_company] + LOOKUP_TOOLS
  }.freeze

  SENTENCE = /[^.!?…\n]+[.!?…]*/
  QUESTION = /\?[^\p{L}\p{N}]*\z/
  CLAUSE_BREAK = /[,;:—–()]|\s-\s|(?<!\p{L})(?:но|а|однако|зато)(?!\p{L})/i
  NEGATION = words('не', 'ни', 'нет')
  IRREALIS = words('чтобы', 'если')
  # What may follow the claim word without making it a claim: "перенесла бы", "создана не была".
  HYPOTHETICAL = /\A\s*(?:бы|(?:(?:ещё|еще|пока|уже)\s+)?(?:не|нет))(?!\p{L})/i
  # An indirect question: "записаны ли вы", "записаны вы или нет", "жазылдыңыз ба".
  INDIRECT_QUESTION = /\A\s*(?:ли|(?:\p{L}+\s+)?или\s+нет|ба|бе|па|пе|ма|ме)(?!\p{L})/i
  RECORDED_DATA = words(
    'номер(?:а|у|ом|е)?', 'телефон(?:а|у|ом|е)?', 'данны(?:е|х|м|ми)', 'имя', 'имени', 'фамили(?:я|ю|и)', 'иин',
    'контакт(?:ы|ов)?', 'коммент\p{L}*', 'пожелани(?:е|я|й)', 'информаци(?:я|ю|и)', 'адрес(?:а|у)?', 'запрос(?:а|у)?'
  )

  def self.kinds(text) = new(text).kinds

  # [[kind, sentence], ...] for every claim found, in text order.
  def self.claims(text) = new(text).claims

  def initialize(text)
    @text = text.to_s
  end

  def kinds
    claims.map(&:first).uniq
  end

  def claims
    sentences.flat_map { |sentence| sentence_kinds(sentence).map { |kind| [kind, sentence] } }
  end

  private

  def sentences
    @text.scan(SENTENCE).map(&:strip).reject(&:empty?)
  end

  def patterns = self.class::PATTERNS

  # A question is never a claim.
  def sentence_kinds(sentence)
    return [] if sentence.match?(QUESTION)

    patterns.filter_map { |kind, pattern| kind if claim?(sentence, pattern, kind) }
  end

  def claim?(sentence, pattern, kind)
    matches(sentence, pattern).any? { |match| genuine?(sentence, match, kind) }
  end

  def matches(sentence, pattern)
    found = []
    position = 0
    while (match = pattern.match(sentence, position))
      found << match
      position = match.end(0)
    end
    found
  end

  def genuine?(sentence, match, kind)
    before = clause(sentence[0...match.begin(0)], :last)
    after = clause(sentence[match.end(0)..], :first)
    return false if before.match?(IRREALIS) || before.split.last(4).join(' ').match?(NEGATION)
    return false if after.match?(HYPOTHETICAL) || after.match?(INDIRECT_QUESTION)

    !(kind.to_s.start_with?('book') && recorded_data?(before, after))
  end

  # "записала ваш номер", "ваш номер записан": the verb is about stored data, not about an appointment.
  def recorded_data?(before, after)
    (before.split.last(3) + after.split.first(2)).join(' ').match?(RECORDED_DATA)
  end

  # The part of the text on one side of the claim that belongs to the same clause.
  def clause(text, edge)
    parts = text.to_s.split(CLAUSE_BREAK, -1)
    (edge == :last ? parts.last : parts.first).to_s
  end
end
