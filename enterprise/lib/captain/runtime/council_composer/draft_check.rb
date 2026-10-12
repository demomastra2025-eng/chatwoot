# frozen_string_literal: true

# Checks a drafted council reply against the data it was written from. The draft is a model's text, so what it says about
# staff, times, prices and the confirmation question is verified here and never trusted. #reason is nil for a draft that
# may go to the customer, otherwise the name of the first check that failed (the council then keeps its fixed templates).
class Captain::Runtime::CouncilComposer::DraftCheck
  STAFF = '(?:сотрудник|администратор|менеджер|оператор|регистратор|коллег|специалист|консультант|қызметкер|әкімші|маман)\p{L}*'
  STAFF_MENTION = /(?<!\p{L})#{STAFF}/i
  # What staff will do for the customer, in the third person ("ответит", "хабарласады").
  STAFF_ACTION = '(?:свяж(?:ется|утся)|перезвон(?:ит|ят)|позвон(?:ит|ят)|ответ(?:ит|ят)|напиш(?:ет|ут)|поможет|помогут|' \
                 'проконсультиру(?:ет|ют)|подскаж(?:ет|ут)|уточн(?:ит|ят)|хабарласады|жауап\s+береді|көмектеседі|байланысады|' \
                 'айтып\s+береді)'
  # Staff and its action within a few words of each other, in either order. Punctuation ends the window.
  STAFF_PROMISE = Regexp.union(
    /(?<!\p{L})#{STAFF}(?:\s+\p{L}+){0,4}\s+#{STAFF_ACTION}(?!\p{L})/i,
    /(?<!\p{L})#{STAFF_ACTION}(?!\p{L})(?:\s+\p{L}+){0,4}\s+#{STAFF}/i
  )
  # A promise of the clinic in the first person ("свяжемся", "передам"): nobody keeps it when no handoff follows.
  CLINIC_PROMISE = /(?<!\p{L})(?:свяж(?:емся|усь)|перезвон(?:им|ю)|позвон(?:им|ю)|вернёмся|вернемся|вернусь|передам|передадим|переведу|
                    переведём|переключу|направлю|направим|хабарласамыз|хабарласамын|жауап\s+береміз|жауап\s+беремін|жіберемін|жібереміз)
                    (?!\p{L})/xi
  TIME = /(?<!\d)(\d{1,2}):(\d{2})(?!\d)/
  THOUSANDS_GAP = /(?<=\d)[ \u00a0](?=\d{3}(?!\d))/
  LATIN_WORD = /\p{Latin}{3,}/

  def initialize(reply:, message:, parts:, staff_handoff:)
    @reply = reply.to_s
    @message = message.to_s
    @parts = Array(parts)
    @staff_handoff = staff_handoff.present?
  end

  def reason
    staff_reason || confirmation_reason || number_reason || latin_reason
  end

  private

  # A staff member is promised only when a real handoff follows the reply, and is always mentioned when one does.
  def staff_reason
    if @staff_handoff
      'staff_missing' unless @reply.match?(STAFF_MENTION)
    elsif @reply.match?(STAFF_PROMISE) || @reply.match?(CLINIC_PROMISE)
      'staff_promise'
    end
  end

  # A part that waits for the customer's yes or no is only asked about with a question.
  def confirmation_reason
    'no_confirmation_question' if @parts.any? { |part| part.to_h['confirm'].present? } && @reply.exclude?('?')
  end

  # Every time and number in the reply must be one that the data or the customer's message contains.
  def number_reason
    source = "#{strings(@parts).join(' ')} #{@message}"
    source = source.gsub(THOUSANDS_GAP, '')
    text = @reply.gsub(THOUSANDS_GAP, '')
    known_times = source.scan(TIME).map { |hours, minutes| [hours.to_i, minutes] }
    return 'unsupported_number' if text.scan(TIME).any? { |hours, minutes| known_times.exclude?([hours.to_i, minutes]) }

    known = source.scan(/\d+/).map { |digits| normalized(digits) }
    'unsupported_number' if text.gsub(TIME, ' ').scan(/\d+/).any? { |digits| known.exclude?(normalized(digits)) }
  end

  # Latin words are internal (a title, a key, a code). Only a word from the customer's message or the data may appear.
  def latin_reason
    known = (strings(@parts) + [@message]).flat_map { |text| text.scan(LATIN_WORD) }.map(&:downcase)
    'latin' if @reply.scan(LATIN_WORD).any? { |word| known.exclude?(word.downcase) }
  end

  def normalized(digits)
    digits.sub(/\A0+(?=\d)/, '')
  end

  # The string values of the data, never its keys.
  def strings(value)
    case value
    when Hash then value.values.flat_map { |item| strings(item) }
    when Array then value.flat_map { |item| strings(item) }
    when String then [value]
    when Numeric then [value.to_s]
    else []
    end
  end
end
