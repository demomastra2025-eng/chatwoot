# frozen_string_literal: true

# Recognises the customer asking for a person ("позовите оператора", "хочу поговорить с живым человеком",
# "администратор керек") in Russian and Kazakh. A fixture turn marks the request with `expect.human_request: true`;
# for a turn that carries no mark this detector decides, and for a marked turn it audits the mark.
#
# The detector is deliberately narrow: a verb that asks for contact (позвать, соединить, поговорить ...) and a target
# (оператор, менеджер, администратор, живой человек, руководство ...) in one sentence, close to each other and not
# negated. A wish verb ("мне нужен", "дайте", "хочу", "керек") needs its target right next to it ("мне нужен администратор",
# "менеджер керек маған", "с человеком хочу"). "Нужна справка для сотрудников" or "администратор клиники сказал" are not
# requests. A fixture should still mark the turn with `human_request: true`; the detector then only audits the mark.
class Captain::Evals::RoutingBenchmark::HumanRequest
  SENTENCE = /[^.!?…\n]+/
  # "свяжите", "связаться" ask for contact; "свяжется" says that a third person will call, which is no request.
  CONTACT_VERBS = /(?<!\p{L})(?:позов\p{L}*|позвать|зовите|соедин\p{L}*|переключ\p{L}*|перевед\p{L}*|подключ\p{L}*|свяж(?:ите|итесь|ись)|
                    связ(?:ать|аться)|поговор\p{L}*|пообщ\p{L}*|переадресуй\p{L}*|пригласи\p{L}*|шақыр\p{L}*|қос(?:ыңыз|ып)|жалға\p{L}*|
                    сөйлес\p{L}*|байланыстыр\p{L}*|хабарлас(?:сын|ыңыз(?:дар)?|ыңдар))/ix
  WISH_VERBS = /(?<!\p{L})(?:нужен|нужна|нужно|нужны|хочу|хотел\p{L}*|можно|дайте|требуется|керек|қалаймын)(?!\p{L})/i
  # "разберётся" and "разобралось" are one wish: the management is to look into the complaint.
  COMPLAINT_VERBS = /(?<!\p{L})(?:пожалов\p{L}*|разбер\p{L}*|разобра\p{L}*|рассмотр\p{L}*|пусть|шағым\p{L}*)/i
  # Unambiguous: asking for these means asking for a person.
  PERSON_TARGET = /(?<!\p{L})(?:оператор\p{L}*|живо\p{L}+\s+человек\p{L}*|реальн\p{L}+\s+человек\p{L}*|живой|тірі\s+адам\p{L}*)/i
  STAFF_TARGET = /(?<!\p{L})(?:администратор(?:а|у|ом|е)?|менеджер(?:а|у|ом|е)?|сотрудник(?:а|у|ом|е)?|человек(?:а|у|ом)?|
                    әкімші\p{L}*|менеджер\p{L}*|қызметкер\p{L}*|адаммен)(?!\p{L})/ix
  MANAGEMENT_TARGET = /(?<!\p{L})(?:руководств\p{L}*|директор\p{L}*|начальств\p{L}*|басшылық\p{L}*|главн\p{L}+\s+врач\p{L}*)/i
  # What a wish verb ("мне нужен администратор", "менеджер керек", "с человеком хочу") may name. Narrower than STAFF_TARGET:
  # a bare "человека" is somebody to be booked, and "сотрудник" is the customer's own staff.
  WISH_TARGET = /(?<!\p{L})(?:администратор(?:а|у|ом|е|ы)?|менеджер\p{L}*|человеком|әкімші\p{L}*|адаммен|адам)(?!\p{L})/i
  NEGATION = /(?<!\p{L})(?:не|без|ненужно|керек\s+емес)(?!\p{L})/i
  # "справка для сотрудника", "администратор үшін": the person is the beneficiary, not the one asked for.
  NOT_A_REQUEST_BETWEEN = /\A(?:для|үшін)\z/i
  MAX_GAP = 7
  # A wish verb and its target stand next to each other: at most one word between them.
  WISH_GAP = 2

  def self.match?(text) = new(text).match?

  def initialize(text)
    @text = text.to_s
  end

  def match?
    @text.scan(SENTENCE).any? { |sentence| request?(sentence) }
  end

  private

  def request?(sentence)
    return true if verb_near?(sentence, CONTACT_VERBS, [PERSON_TARGET, STAFF_TARGET, MANAGEMENT_TARGET])
    return true if verb_near?(sentence, WISH_VERBS, [PERSON_TARGET, WISH_TARGET], gap: WISH_GAP, blocked_between: NOT_A_REQUEST_BETWEEN)

    verb_near?(sentence, COMPLAINT_VERBS, [MANAGEMENT_TARGET])
  end

  # A verb and a target within `gap` words of each other, with no negation in the three words before the verb and none
  # of the `blocked_between` words between them.
  def verb_near?(sentence, verb_pattern, target_patterns, gap: MAX_GAP, blocked_between: nil)
    words = sentence.scan(/\S+/)
    verbs = positions(words, verb_pattern)
    targets = target_patterns.flat_map { |pattern| positions(words, pattern, sentence) }
    verbs.any? do |verb|
      next false if negated?(words, verb)

      targets.any? { |target| (target - verb).abs <= gap && !blocked?(words, verb, target, blocked_between) }
    end
  end

  def blocked?(words, verb, target, pattern)
    return false unless pattern

    first, last = [verb, target].minmax
    words[(first + 1)...last].any? { |word| word.match?(pattern) }
  end

  # A negation in the same clause, within the three words before the verb.
  def negated?(words, verb)
    window = words[[verb - 3, 0].max...verb]
    cut = window.rindex { |word| word.match?(/[,;:]\z/) }
    window = window[(cut + 1)..] if cut
    window.any? { |word| word.match?(NEGATION) }
  end

  # Word indexes where the pattern matches. A pattern with a space ("живого человека") is matched on the sentence.
  def positions(words, pattern, sentence = nil)
    found = words.each_index.select { |index| words[index].match?(pattern) }
    return found if found.any? || sentence.nil?

    sentence.to_enum(:scan, pattern).map { words.index { |word| word.include?(Regexp.last_match(0).split.first) } }.compact
  end
end
