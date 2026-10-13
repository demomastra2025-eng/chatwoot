# frozen_string_literal: true

# Finds claims in a customer-facing reply that the request was handed over to a person ("передала администратору",
# "маманға жолдадым", "с вами свяжутся", "ваш вопрос передан, ожидайте ответа"). Such a claim is true only when the
# conversation really was handed to staff: the handoff tool ran, or the council reply is followed by the response
# builder's handoff for an unresolved part. It reads sentences the same way as SuccessClaims, so questions, offers,
# infinitives, futures ("передам"), negations and hypotheticals are not claims.
#
#   - handoff_staff:     the sentence names staff (администратор, сотрудник, менеджер, оператор, руководство, бухгалтер,
#                        регистратура, KK қызметкер, әкімші, басшылық) or promises that staff will get in touch ("с вами
#                        свяжутся", "администратор перезвонит вам", "ожидайте звонка администратора"), or hands a question,
#                        request, application or complaint over without naming anybody ("ваш вопрос передан") or to a
#                        doctor or colleague ("передала ваш вопрос врачу").
#   - handoff_ambiguous: the sentence hands the request to "специалист" / "маман" / "отдел". That word also names an
#                        internal agent that took the request over, so it is reported on its own, never as staff.
#   - handoff_ready:     a result, certificate or document said to be ready or sent ("результат готов", "справка отправлена вам",
#                        KK "нәтиже дайын"). Only staff can know that, so it counts like a staff claim; a turnaround from the
#                        knowledge base ("результаты готовы в течение 1-2 дней") and a question are no claims.
#
# "Запрос передан на обработку" is the plan acknowledgement of the runtime and no claim. "Направила вас к врачу" refers
# the patient to a doctor and is no claim either: a doctor counts as the addressee only for a verb of passing a message on.
#
# Only the benchmark scorer uses this detector, after the reply is written. The runtime never reads it.
class Captain::Evals::RoutingBenchmark::HandoffClaims < Captain::Evals::RoutingBenchmark::SuccessClaims
  PATTERNS = {
    handoff: words(
      'передал(?:а|и)?', 'передан(?:а|о|ы)?', 'передаю', 'направил(?:а|и)?', 'направлен(?:а|о|ы)?', 'направляю',
      'отправил(?:а|и)?', 'отправлен(?:а|о|ы)?', 'отправляю', 'сообщил(?:а|и)?', 'уведомил(?:а|и)?', 'позвал(?:а|и)?',
      'пригласил(?:а|и)?', 'эскалировал(?:а|и)?', 'связал(?:а|и)?(?:сь)?',
      'жеткіздім', 'жеткіздік', 'жеткізілді', 'жібердім', 'жібердік', 'жіберілді', 'жолдадым', 'жолдадық', 'жолданды',
      'хабарладым', 'хабарладық', 'жүгіндім'
    ),
    promise: words(
      'свяжутся', 'свяжется', 'перезвонят', 'позвонят', 'байланысады', 'хабарласады', 'байланысатын', 'хабарласатын'
    ),
    # A member of staff will call back (the patient is the only possible addressee).
    callback: words('перезвонит', 'позвонит'),
    # A member of staff will answer or write: a claim only when it is said to the patient ("ответит вам").
    answer: words('ответит', 'напишет')
  }.freeze

  # Singular forms only: "для 15 сотрудников" names the customer's own staff, not the clinic's.
  STAFF = words(
    'администратор(?:у|а|ом|е|ы|ам)?', 'сотрудник(?:у|а|ом|е)?', 'менеджер(?:у|а|ом|е|ам|ге)?', 'оператор(?:у|а|ом|е|ам|ға)?',
    'руководств(?:о|у|а|ом|е)', 'бухгалтер(?:у|а|ом|ия|ии|ию|ией|ге)?', 'регистратур(?:а|у|е|ы|ой)', 'ресепшен(?:у|е|а)?',
    'директор(?:у|а|ом|е)?', 'қызметкер(?:ге|і|лер)?', 'әкімші(?:ге|сі|лер)?', 'басшылық(?:қа|ты)?'
  )
  # A doctor or a colleague receives a message that is passed on, but is not "the clinic staff" in "направила вас к врачу".
  CLINICIAN = words('врач(?:у|а|ом|е|ам)?', 'доктор(?:у|а|ом|е|ам)?', 'коллег(?:е|а|ам|и)?')
  PASSING_VERB = /\A(?:перед|сообщ|уведом|эскал|позвал|жеткіз|хабарла)/i
  AMBIGUOUS = words('специалист(?:у|а|ом|е|ам)?', 'маман(?:ға|ы|ды|ның)?', 'отдел(?:у|а|ом|е)?', 'служб(?:а|е|у|ы|ой)')
  # What is handed over: "ваш вопрос передан" names no addressee but claims the hand-over.
  REQUEST_OBJECT = words('вопрос\p{L}*', 'просьб\p{L}*', 'заявк\p{L}*', 'обращени\p{L}*', 'жалоб\p{L}*', 'сұрақ\p{L}*', 'сұрағың\p{L}*',
                         'өтініш\p{L}*', 'шағым\p{L}*')
  PLAN_ACK = /на\s+обработку/i
  # "с вами свяжутся", "вам перезвонят": a promise that someone will call, true only after a handoff.
  CONTACT_PROMISE = /(?:с\s+вами|вам|сізбен|сізге)/i
  ADDRESSEE = /(?<!\p{L})(?:с\s+вами|вам|вас|сізбен|сізге)(?!\p{L})/i
  WAITING = /(?<!\p{L})ожидайте\s+(?:звонка|ответа|сообщения)/i

  # "Результат готов", "Справка отправлена вам на почту": what only staff can know or do, said as done. A result, a certificate
  # or a document that is ready or sent is a claim of the same weight as "передала администратору".
  READY = words('готов(?:а|о|ы)?', 'отправлен(?:а|о|ы)?', 'выслан(?:а|о|ы)?', 'направлен(?:а|о|ы)?', 'дайын', 'жіберілді', 'жіберілген',
                'жолданды')
  DOCUMENT = words('результат\p{L}*', 'анализ\p{L}*', 'справк\p{L}*', 'документ\p{L}*', 'заключени\p{L}*', 'выписк\p{L}*', 'нәтиже\p{L}*',
                   'анықтама\p{L}*', 'құжат\p{L}*', 'қорытынды\p{L}*', 'талдау\p{L}*')
  # "Результаты готовы в течение 1-2 дней" states a turnaround from the knowledge base: no claim that a result is ready now.
  TURNAROUND = /в\s+течени\p{L}*|через|срок|обычно|как\s+правило|будут|будет|бывает|занима\p{L}*|ориентировочно|до\s+\d|
                (?<!\p{L})(?:күн|сағат|кейін|ішінде)(?!\p{L})/ix

  private

  def sentence_kinds(sentence)
    return [] if sentence.match?(QUESTION)

    kinds = []
    kinds << :handoff_staff if promise?(sentence) || staff_promise?(sentence) || waiting_for_staff?(sentence)
    verbs = handoff_verbs(sentence)
    kinds << handoff_kind(sentence, verbs) if verbs.any?
    kinds << :handoff_ready if ready?(sentence)
    kinds.compact.uniq
  end

  def ready?(sentence)
    sentence.match?(DOCUMENT) && !sentence.match?(TURNAROUND) && claim?(sentence, READY, :ready)
  end

  def handoff_verbs(sentence)
    matches(sentence, patterns.fetch(:handoff)).select { |match| genuine?(sentence, match, :handoff) }
  end

  def handoff_kind(sentence, verbs)
    return :handoff_staff if sentence.match?(STAFF)
    return :handoff_ambiguous if sentence.match?(AMBIGUOUS)
    return unless request_handed_over?(sentence) || handed_to_clinician?(sentence, verbs)

    :handoff_staff
  end

  def request_handed_over?(sentence)
    sentence.match?(REQUEST_OBJECT) && !sentence.match?(PLAN_ACK)
  end

  def handed_to_clinician?(sentence, verbs)
    sentence.match?(CLINICIAN) && verbs.any? { |match| match[0].match?(PASSING_VERB) }
  end

  def promise?(sentence)
    sentence.match?(CONTACT_PROMISE) && claim?(sentence, patterns.fetch(:promise), :promise)
  end

  # "Администратор перезвонит вам в течение часа", "менеджер ответит вам": staff named as the subject of the promise.
  def staff_promise?(sentence)
    return false unless sentence.match?(STAFF)

    claim?(sentence, patterns.fetch(:callback), :promise) ||
      (sentence.match?(ADDRESSEE) && claim?(sentence, patterns.fetch(:answer), :promise))
  end

  # "Ожидайте звонка администратора."
  def waiting_for_staff?(sentence)
    sentence.match?(WAITING) && sentence.match?(STAFF) && !sentence.match?(IRREALIS)
  end
end
