# Detect an affirmative public promise, not a request, quotation or a proposal
# awaiting approval. This check never performs or authorizes a handoff.
module Captain::Assistant::HandoffClaim
  STAFF = '(?:сотрудник\p{L}*|оператор\p{L}*|администратор\p{L}*|менеджер\p{L}*|руководител\p{L}*|человек\p{L}*)'.freeze
  RU_DONE = '(?:передал[аи]?|передан[аоы]?|передаю|перевел[аи]?|переведен[аоы]?|перевожу|' \
            'перенаправил[аи]?|перенаправлен[аоы]?|перенаправляю|переключил[аи]?|переключен[аоы]?|переключаю|' \
            'соединил[аи]?|соединяю|подключил[аи]?|подключаю)'.freeze
  RU_FUTURE = '(?:передам|переведу|перенаправлю|переключу|соединю|подключу)'.freeze
  CLAUSE_START = "(?:я|мы|i|we|#{RU_DONE}|#{RU_FUTURE})".freeze
  CLAUSE_BOUNDARY = /;|(?:,|\s+(?:и|and))\s*(?=#{CLAUSE_START}(?!\p{L}))|\s+(?:но|однако|but|however)\s+/i
  RU_CLAIM = /(?<!\p{L})(#{RU_DONE}|#{RU_FUTURE})(?!\p{L}).{0,100}?#{STAFF}/i
  EN_SUBJECT = "(?:(?:i|we)(?:\\s+(?:have|will|am|are))?|(?:i|we)['’](?:ve|ll|m|re))".freeze
  EN_CLAIM = Regexp.new(
    "\\b#{EN_SUBJECT}\\s+(?:already\\s+)?" \
    '(?:transfer(?:red|ring)?|forward(?:ed|ing)?|hand(?:ed|ing)?\s+off|connect(?:ed|ing)?)' \
    '\b.{0,90}?\b(?:staff|operator|administrator|manager|human|person)\b', Regexp::IGNORECASE
  )
  EN_PASSIVE = Regexp.new(
    '\b(?:your|the)\s+(?:request|query|conversation|chat|case)\s+(?:has|have)\s+been\s+(?:already\s+)?' \
    '(?:transferred|forwarded|handed\s+off|connected)\b.{0,90}?\b(?:staff|operator|administrator|manager|human|person)\b', Regexp::IGNORECASE
  )
  KK_CLAIM = Regexp.new(
    '(?:кызметкерге|акимшиге|операторга|басшыга).{0,70}?' \
    '(?:жибердим|жиберемин|бердим|беремин|тапсырдым|тапсырамын|багыттадым|багыттаймын|костым|косамын)', Regexp::IGNORECASE
  )
  CONDITIONAL = Regexp.new(
    '(?:если|когда|после.{0,45}(?:подтвержд|соглас)|с вашего разрешения|могу|можем|можно|хотите|' \
    'would|could|can i|can we|once|after.{0,35}(?:approv|confirm)|if\b|егер|растаган|растау|руксат)', Regexp::IGNORECASE
  )
  NEGATED = /(?:не|not|never|жок)\s+(?:\p{L}+\s+){0,2}(?:#{RU_DONE}|#{RU_FUTURE}|transfer|forward|hand|connect)/i
  DONE = /\A#{RU_DONE}\z/i
  REPORTED = /(?:оператор|сотрудник|пациент|вы|правил\p{L}*|инструкц\p{L}*).{0,35}(?:сказал|написал|сообщил|указан)/
  OTHER_SUBJECT = /(?<!\p{L})(?:вы|они|он|она|пациент|сотрудник|оператор)(?:\s+\p{L}+){0,2}\s*\z/i
  CONDITIONAL_PREFIX = /(?:если|когда|\bif\b|\bwhen\b|\bonce\b|егер)/i
  EN_DONE = /\b(?:transferred|forwarded|handed|connected|transferring|forwarding|handing|connecting)\b/i
  KK_DONE = /(?:жибердим|бердим|тапсырдым|багыттадым|костым)/i

  module_function

  def asserted?(text)
    # Quoted words belong to their author, not to the assistant's current action.
    public_text = text.to_s.gsub(/«[^»]*»|“[^”]*”|"[^"]*"/m, ' ')
    Captain::PatientIntent.folded(public_text).scan(/[^.!?]+[.!?]?/).any? do |sentence|
      !sentence.end_with?('?') && sentence.split(CLAUSE_BOUNDARY).any? { |clause| affirmative_claim?(clause) }
    end
  end

  def affirmative_claim?(sentence)
    return false if sentence.match?(REPORTED) || sentence.match?(NEGATED)

    russian = sentence.match(RU_CLAIM)
    return russian_claim?(sentence, russian) if russian

    english = sentence.match(EN_CLAIM) || sentence.match(EN_PASSIVE)
    return claim_asserted?(sentence, english, english[0].match?(EN_DONE)) if english

    kazakh = sentence.match(KK_CLAIM)
    kazakh.present? && claim_asserted?(sentence, kazakh, kazakh[0].match?(KK_DONE))
  end

  def russian_claim?(sentence, match)
    prefix = sentence[0...match.begin(0)]
    return false if prefix.match?(OTHER_SUBJECT)

    claim_asserted?(sentence, match, match[1].match?(DONE))
  end

  def claim_asserted?(sentence, match, completed)
    return false if sentence[0...match.begin(0)].match?(CONDITIONAL_PREFIX)
    return true if completed

    !sentence.match?(CONDITIONAL)
  end
end
