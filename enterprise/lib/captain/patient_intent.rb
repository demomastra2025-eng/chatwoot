# frozen_string_literal: true

# What the words of a patient message ask for, read from keywords of Russian and Kazakh. Two checks guard a decision of a model with the
# words themselves (patient text is only read here, never kept or logged):
#
#   booking_change?  the message asks to cancel, move or make a visit («Отмена завтра», «не смогу прийти», «запишите», «болдырмаңыз»,
#                    «ауыстырыңыз», «келе алмаймын», «жазылғым келеді»). A reply suggestion that ended with «no reply needed» for such a
#                    message swallowed a request (suggestion eval of 26.10: «Отмена завтра» followed by an emoji got no_reply), so the
#                    classifier turns it into a note for the manager (see Captain::ReplySuggestion::AgentOutcomeClassifier).
#   human_request?   the message asks for a person, an operator or a call-back, or is a complaint, a refund or a legal matter («соедините
#                    с оператором», «верните деньги», «шағым», «оператормен байланыстырыңыз»). The router takes a human_handoff of the
#                    decision model only for such a message (see Captain::Runtime::DecisionRouter::Questions): the eval of 26.10 sent
#                    a question about free times for a child, the first message of a dialog, to staff.
#
# The text is compared in lower case with the Kazakh letters folded to the Russian ones (ә→а, ғ→г, қ→к, ң→н, ө→о, ұ→ү→у, һ→х, і→и),
# because patients write Kazakh on a Russian keyboard without them. A stem matches at the start of a word, with any ending.
module Captain::PatientIntent
  FOLDS = {
    'ё' => 'е', 'ә' => 'а', 'ғ' => 'г', 'қ' => 'к', 'ң' => 'н', 'ө' => 'о', 'ұ' => 'у', 'ү' => 'у', 'һ' => 'х', 'і' => 'и'
  }.freeze
  FOLD_PATTERN = Regexp.union(FOLDS.keys)

  # Cancel, move or make a visit (the stems are folded).
  BOOKING_CHANGE_STEMS = [
    # Russian: отмена, перенос, запись; «не смогу / не приду» is a cancellation
    'отмен', 'перенес', 'перенос', 'перезапис', 'передвин', 'сдвин', 'запиш', 'записат', 'записыв', 'не смогу', 'не сможем', 'не приду',
    'не придем', 'не успе', 'на другое время', 'на другой день',
    # Kazakh: болдырмау, ауыстыру, көшіру, келе алмау, жазылу, жазып қою
    'болдырма', 'ауыстыр', 'кошир', 'келе алмай', 'бара алмай', 'келмей', 'бармай', 'жазыл', 'жазып кой', 'жазып бер', 'жазыныз', 'жазсаныз',
    'жойыныз', 'жойып', 'баска уакыт'
  ].freeze

  # A person, an operator, a call-back, a complaint, a refund or a legal matter (the stems are folded).
  HUMAN_STEMS = [
    # Russian: a person or an operator, a call-back, a complaint, a refund, a legal matter
    'оператор', 'администратор', 'менеджер', 'сотрудник', 'консультант', 'руководител', 'директор', 'главврач', 'главн\p{L}* врач',
    'начальник', 'живо\p{L}* человек', 'живо\p{L}* оператор', '(?:с|к) человек', 'не бот', 'не робот', 'бот', 'робот', 'позвоните',
    'позвонить мне', 'перезвоните', 'перезвонить мне', 'наберите', 'свяжитесь', 'соедините', 'переключите', 'позовите',
    'хочу поговорить', 'хочу связаться', 'обратн\p{L}* звон', 'жалоб', 'жалуюсь', 'пожалуюсь', 'претензи', 'возврат', 'верните',
    'вернуть деньги', 'возмест', 'компенсац', 'обман', 'мошенн', 'судебн', 'суд', 'иск', 'прокуратур', 'юрист', 'адвокат', 'полици',
    'роспотреб', 'защит\p{L}* прав',
    # Kazakh: a person or an operator, a call-back, a complaint, a refund, a legal matter
    'тири адам', 'адаммен', 'акимши', 'кызметкер', 'басшы', 'байланыстыр', 'хабарлас', 'конырау шал', 'шагым', 'арыз', 'акшамды кайтар',
    'кайтарыныз', 'кайтарым', 'сот', 'зангер', 'прокуратура'
  ].freeze

  # \p{L} in a stem is a letter of the same word; spaces are any run of spaces.
  def self.pattern(stems)
    parts = stems.map { |stem| stem.gsub(' ', '[[:space:]]+') }
    Regexp.new("(?<![[:alpha:]])(?:#{parts.join('|')})", Regexp::IGNORECASE)
  end
  private_class_method :pattern

  BOOKING_CHANGE = pattern(BOOKING_CHANGE_STEMS)
  # «суд» and «иск» are whole words (not «судороги», «искать»), the others stems.
  HUMAN = pattern(HUMAN_STEMS - %w[суд иск сот])
  WHOLE_WORD_HUMAN = /(?<![[:alpha:]])(?:суд|иск|сот)(?:у|а|е|ы|ом|ка|ке|ты|ти|тан|тен|пен)?(?![[:alpha:]])/

  module_function

  # The patient asks to cancel, move or make a visit.
  def booking_change?(text)
    folded(text).match?(BOOKING_CHANGE)
  end

  # The patient asks for a person, an operator or a call-back, or complains, asks for a refund or raises a legal matter.
  def human_request?(text)
    folded = folded(text)
    folded.match?(HUMAN) || folded.match?(WHOLE_WORD_HUMAN)
  end

  def folded(text)
    text.to_s.downcase.gsub(FOLD_PATTERN, FOLDS).squish
  end
end
