# frozen_string_literal: true

# Finds claims in a customer-facing reply that the request was handed over to a person ("передала администратору",
# "маманға жолдадым", "с вами свяжутся"). Such a claim is true only when the conversation really was handed to staff:
# the handoff tool ran, or the council reply is followed by the response builder's handoff. It reads sentences the same
# way as SuccessClaims, so questions, offers, infinitives, futures ("передам"), negations and hypotheticals are not
# claims.
#
#   - handoff_staff:     the sentence names staff (администратор, сотрудник, менеджер, оператор, руководство, бухгалтер,
#                        регистратура, KK қызметкер, әкімші, басшылық) or promises that staff will get in touch.
#   - handoff_ambiguous: the sentence hands the request to "специалист" / "маман" / "отдел". That word also names an
#                        internal agent that took the request over, so it is reported on its own, never as staff.
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
    )
  }.freeze

  # Singular forms only: "для 15 сотрудников" names the customer's own staff, not the clinic's.
  STAFF = words(
    'администратор(?:у|а|ом|е|ы|ам)?', 'сотрудник(?:у|а|ом|е)?', 'менеджер(?:у|а|ом|е|ам|ге)?', 'оператор(?:у|а|ом|е|ам|ға)?',
    'руководств(?:о|у|а|ом|е)', 'бухгалтер(?:у|а|ом|ия|ии|ию|ией|ге)?', 'регистратур(?:а|у|е|ы|ой)', 'ресепшен(?:у|е|а)?',
    'директор(?:у|а|ом|е)?', 'қызметкер(?:ге|і|лер)?', 'әкімші(?:ге|сі|лер)?', 'басшылық(?:қа|ты)?'
  )
  AMBIGUOUS = words('специалист(?:у|а|ом|е|ам)?', 'маман(?:ға|ы|ды|ның)?', 'отдел(?:у|а|ом|е)?', 'служб(?:а|е|у|ы|ой)')
  # "с вами свяжутся", "вам перезвонят": a promise that someone will call, true only after a handoff.
  CONTACT_PROMISE = /(?:с\s+вами|вам|сізбен|сізге)/i

  private

  def sentence_kinds(sentence)
    return [] if sentence.match?(QUESTION)

    kinds = []
    kinds << :handoff_staff if promise?(sentence)
    if claim?(sentence, patterns.fetch(:handoff), :handoff)
      if sentence.match?(STAFF)
        kinds << :handoff_staff
      elsif sentence.match?(AMBIGUOUS)
        kinds << :handoff_ambiguous
      end
    end
    kinds.uniq
  end

  def promise?(sentence)
    sentence.match?(CONTACT_PROMISE) && claim?(sentence, patterns.fetch(:promise), :promise)
  end
end
