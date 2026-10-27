# frozen_string_literal: true

# What the words of a patient message ask for, read from keywords of Russian, Kazakh and English. Two checks guard a decision of a model
# with the words themselves (patient text is only read here, never kept or logged):
#
#   booking_change?  the message asks to cancel, move or make a visit («Отмена завтра», «не смогу прийти», «запишите», «болдырмаңыз»,
#                    «ауыстырыңыз», «келе алмаймын», «жазылғым келеді»). A reply suggestion that ended with «no reply needed» for such a
#                    message swallowed a request (suggestion eval of 26.10: «Отмена завтра» followed by an emoji got no_reply), so the
#                    classifier turns it into a note for the manager (see Captain::ReplySuggestion::AgentOutcomeClassifier). A thanks that
#                    only names the action as done («Спасибо, что перенесли», «Благодарю за перенос», «Рахмет, жазылдым») asks for
#                    nothing: it stays a no_reply.
#   human_request?   the message asks for a person, an operator, an administrator or a call-back, or is a complaint, a refund, a demand
#                    to stop writing or a legal matter («соедините с оператором», «можете позвонить?», «хочу пожаловаться», «отдайте мои
#                    деньги», «перестаньте мне писать», «шағым», «админге қосыңыз», «please call me»). The router takes a human_handoff of
#                    the decision model for such a message whatever the include answers say; for any other message the most probable agent
#                    answers (see Captain::Runtime::DecisionRouter::Questions): the evals of 26.10 and 27.10 sent a question about free
#                    times for a child, the first message of a dialog, to staff.
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

  # A thanks (the stems are folded): «спасибо», «благодарю», «рахмет» and «рақмет», «алғыс», «thanks».
  THANKS_STEMS = %w[спасиб спс благодар рахмет ракмет алгыс thank thx].freeze

  # An action named as done, in the words of a thanks («Спасибо, что перенесли», «Благодарю за перенос», «Рақмет, жазылдым»): it asks for
  # nothing, so it is no request to cancel, move or make a visit. Only the past tense, the short participle and the noun after «за» are
  # listed, never the imperative («отмените», «перенесите», «ауыстырыңыз»), which stays a request.
  DONE_STEMS = [
    # Russian: «отменили», «отменена», «перенесли», «перенесено», «передвинули», «сдвинуты», «за отмену», «за перенос»
    'отменил', 'отменен', 'перенесл', 'перенесен', 'перезаписал', 'передвинул', 'передвинут', 'сдвинул', 'сдвинут', 'за отмен', 'за перенос',
    'за перезапис',
    # Kazakh: «жазылдым», «жазылдық», «ауыстырдыңыз», «ауыстырғаныңызға», «көшірдіңіз», «көшірілді»
    'жазылд', 'ауыстырд', 'ауыстырг', 'коширд', 'коширг', 'коширил'
  ].freeze

  # A person, an operator, an administrator, a call-back, a complaint, a refund or a legal matter (the stems are folded). A message that
  # carries one of them asks for staff whatever the include answers of the router say; a message that carries none goes to an agent,
  # which can still end with human_needed, so the list leans to the words patients really use.
  HUMAN_STEMS = [
    # Russian: a person, an operator, an administrator, the front desk, a manager
    'оператор', 'админ', 'менеджер', 'сотрудник', 'консультант', 'регистратур', 'ресепш', 'руководител', 'директор', 'главврач',
    'главн\p{L}* врач', 'начальник', 'живо\p{L}* человек', 'живо\p{L}* оператор', '(?:с|к) человек', 'не бот', 'не робот',
    'бот(?:а|у|ом|е|ы|ов)?(?![[:alpha:]])', 'робот(?:а|у|ом|е|ы|ов)?(?![[:alpha:]])',
    # Russian: a call, a call-back, to get in touch or to talk («позвоночник», «позвонок» and «позвоню» are no call)
    'позвон(?!о[кч]|к|ю)', 'перезвон', 'звон(?:и|ок|к)', 'набери(?:те)?(?![[:alpha:]])', 'свяж', 'связат', 'соедин', 'переключ',
    'переведит', 'позов', 'позвать', 'зовите', 'поговор', 'пообщ',
    # Russian: a complaint, dissatisfaction, a demand to stop writing («добро пожаловать» is no complaint)
    'жалов', 'пожаловат\p{L}*с', 'пожаловалс', 'жалоб', 'жалуюсь', 'пожалуюсь', 'претензи', 'недовол', 'не довол', 'возмущ', 'возмути', 'безобраз',
    'хамств', 'нахамил', 'нагруб', 'плох\p{L}* обслужив', 'ужасн\p{L}* обслужив', 'перестань', 'прекратите', 'прекрати(?![[:alpha:]])',
    'хватит писать', 'не пиши', 'отстан', 'не беспокой',
    # Russian: a refund, a legal matter
    'возврат', 'верните', 'вернуть деньги', 'мои деньги', 'свои деньги', 'деньги назад', 'деньги обратно', 'отда\p{L}*(?: \p{L}+)? деньг',
    'возмест', 'компенсац', 'обман', 'мошенн', 'судебн', 'суд', 'иск', 'прокуратур', 'юрист', 'адвокат', 'полици', 'роспотреб', 'минздрав',
    'министерств', 'защит\p{L}* прав',
    # Kazakh: a person or an operator, a call-back, a complaint, a refund, a legal matter
    'тири адам', 'адаммен', 'акимши', 'кызметкер', 'басшы', 'бас даригер', 'байланыстыр', 'хабарлас', 'конырау', 'звонда', 'шагым', 'арыз',
    'наразы', 'акшамды кайтар', 'кайтарыныз', 'кайтарым', 'сот', 'зангер', 'прокуратура',
    # English
    'operator', 'admin', 'manager', 'human', 'real person', 'live person', 'staff', 'reception', 'call me', 'call back', 'callback',
    'phone me', 'talk to', 'talk with', 'speak to', 'speak with', 'complain', 'refund', 'lawyer', 'bot(?:s)?(?![[:alpha:]])'
  ].freeze

  # \p{L} in a stem is a letter of the same word; spaces are any run of spaces. whole_word: the match takes the rest of the word too.
  def self.pattern(stems, whole_word: false)
    parts = stems.map { |stem| stem.gsub(' ', '[[:space:]]+') }
    Regexp.new("(?<![[:alpha:]])(?:#{parts.join('|')})#{'[[:alpha:]]*' if whole_word}", Regexp::IGNORECASE)
  end
  private_class_method :pattern

  BOOKING_CHANGE = pattern(BOOKING_CHANGE_STEMS)
  THANKS = pattern(THANKS_STEMS)
  DONE = pattern(DONE_STEMS, whole_word: true)
  # «суд» and «иск» are whole words (not «судороги», «искать»), the others stems.
  HUMAN = pattern(HUMAN_STEMS - %w[суд иск сот])
  WHOLE_WORD_HUMAN = /(?<![[:alpha:]])(?:суд|иск|сот)(?:у|а|е|ы|ом|ка|ке|ты|ти|тан|тен|пен)?(?![[:alpha:]])/

  module_function

  # The patient asks to cancel, move or make a visit. A thanks that only names the action as done is no request: the words of that
  # action are left out of a thanks before the check, so «Спасибо, что перенесли» is none, while «Спасибо, перенесите на пятницу» is one.
  def booking_change?(text)
    folded = folded(text)
    return false unless folded.match?(BOOKING_CHANGE)
    return true unless folded.match?(THANKS)

    folded.gsub(DONE, ' ').match?(BOOKING_CHANGE)
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
