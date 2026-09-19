class Captain::Tools::HandoffConsentPolicy
  PERSON_PATTERN = '(?:сотрудник|оператор|менеджер|администратор|человек|врач|доктор|' \
                   'қызметкер|оператор|менеджер|әкімші|адам|дәрігер|human|agent|manager|doctor)'.freeze
  TRANSFER_PATTERN = '(?:соедин|подключ|переключ|переда|позов|қос|байланыстыр|ауыстыр|connect|transfer)'.freeze
  NEGATED_TRANSFER_PATTERN = /
    не\s+(?:надо|нужно|хочу)[^,.;!?]{0,30}#{TRANSFER_PATTERN}|
    не\s+(?:хочу|желаю|нужно)[^,.;!?]{0,30}?(?:поговорить|связаться)[^,.;!?]{0,40}?#{PERSON_PATTERN}|
    не\s+(?:соединяйте|подключайте|переключайте|передавайте|зовите)|
    (?:қоспаңыз|байланыстырмаңыз|ауыстырмаңыз|қажет\s+емес)|
    (?:don't|do\s+not)\s+(?:connect|transfer)|
    (?:no\s+need|don't\s+want).{0,30}#{TRANSFER_PATTERN}
  /ix
  DIRECT_REQUEST_PATTERNS = [
    /(?:соедините|подключите|переключите|передайте|позовите).{0,60}#{PERSON_PATTERN}/i,
    /не\s+могли\s+бы\s+вы.{0,20}(?:соединить|подключить|переключить|передать).{0,60}#{PERSON_PATTERN}/i,
    /(?:хочу|хотел(?:а)?\s+бы|мне\s+нужно).{0,40}(?:поговорить|связаться).{0,40}#{PERSON_PATTERN}/i,
    /(?:қосыңыз|байланыстырыңыз|ауыстырыңыз).{0,60}#{PERSON_PATTERN}/i,
    /(?:connect|transfer)\s+(?:me\s+)?(?:to|with).{0,40}#{PERSON_PATTERN}/i,
    /(?:i\s+(?:want|need|would\s+like)\s+to).{0,30}(?:speak|talk).{0,30}#{PERSON_PATTERN}/i
  ].freeze
  STANDALONE_AFFIRMATIVE_PATTERN = /
    \A(?:да(?:,?\s+пожалуйста)?|хорошо|ладно|ок(?:ей)?|соглас(?:ен|на)|иә|ия|жарайды|
    yes(?:,?\s+please)?|ok(?:ay)?|please\s+do|передайте|подключите|соедините|переключите|
    қосыңыз|байланыстырыңыз|ауыстырыңыз)[\s.!]*\z
  /ix
  HANDOFF_OFFER_PATTERNS = [
    /(?:хотите|желаете).{0,60}#{TRANSFER_PATTERN}.{0,60}#{PERSON_PATTERN}/i,
    /(?:могу|можем|давайте).{0,40}#{TRANSFER_PATTERN}.{0,60}#{PERSON_PATTERN}/i,
    /#{TRANSFER_PATTERN}.{0,60}#{PERSON_PATTERN}.{0,10}\?\z/i,
    /(?:would\s+you\s+like|do\s+you\s+want\s+me|shall\s+i).{0,60}#{TRANSFER_PATTERN}.{0,60}#{PERSON_PATTERN}/i
  ].freeze
  NEGATED_EMERGENCY_PATTERN = /
    не\s+(?:умираю|задыхаюсь)|
    не\s+хочу\s+покончить\s+с\s+собой|
    не\s+пытаюсь\s+убить\s+себя|
    не\s+сильн\w*\s+боль\w*\s+в\s+груди|
    сильн\w*\s+(?:боль\w*\s+в\s+груди|кровотеч\w*)\s+нет
  /ix
  NEGATED_HANDOFF_OFFER_PATTERN = /не\s+(?:могу|можем).{0,30}#{TRANSFER_PATTERN}/i
  EMERGENCY_PATTERN = /
    (?:не\s+могу\s+дышать|без\s+сознания|потерял[аи]?\s+сознание|сильн\w*\s+боль\w*\s+в\s+груди|
    сильн\w*\s+кровотеч|задыхаюсь|хочу\s+покончить\s+с\s+собой|пытаюсь\s+убить\s+себя|умираю|
    дем\s+ала\s+алмай|ес-түссіз)
  /ix

  def initialize(assistant:, conversation:, state:)
    @assistant = assistant
    @conversation = conversation
    @state = state.to_h.with_indifferent_access
  end

  def authorized?
    incoming_message = triggering_incoming_message
    return false if incoming_message.blank?

    content = normalized_content(incoming_message)
    emergency_signal?(content) || explicit_consent?(content, incoming_message)
  end

  private

  attr_reader :assistant, :conversation, :state

  def emergency_signal?(content)
    content_without_negated_signals = content.gsub(NEGATED_EMERGENCY_PATTERN, ' ')
    content_without_negated_signals.match?(EMERGENCY_PATTERN)
  end

  def explicit_consent?(content, incoming_message)
    content_without_negated_signals = content.gsub(NEGATED_TRANSFER_PATTERN, ' ')
    return true if DIRECT_REQUEST_PATTERNS.any? { |pattern| content_without_negated_signals.match?(pattern) }
    return false unless content.match?(STANDALONE_AFFIRMATIVE_PATTERN)

    handoff_offer?(previous_public_message(incoming_message))
  end

  def triggering_incoming_message
    expected_message_id = state.dig(:captain_response_fence, :last_message_id)
    return if expected_message_id.blank?

    scope = conversation.messages.where(private: false, message_type: :incoming)
    scope.find_by(id: expected_message_id)
  end

  def previous_public_message(incoming_message)
    conversation.messages.where(private: false)
                .where(
                  'created_at < :created_at OR (created_at = :created_at AND id < :id)',
                  created_at: incoming_message.created_at,
                  id: incoming_message.id
                )
                .reorder(created_at: :desc, id: :desc)
                .first
  end

  def handoff_offer?(message)
    return false unless message&.message_type == 'outgoing'
    return false unless message.sender_type == 'Captain::Assistant' && message.sender_id == assistant.id

    content = normalized_content(message)
    return false if negated_handoff_offer?(content)

    HANDOFF_OFFER_PATTERNS.any? { |pattern| content.match?(pattern) }
  end

  def negated_handoff_offer?(content)
    content.match?(NEGATED_TRANSFER_PATTERN) || content.match?(NEGATED_HANDOFF_OFFER_PATTERN)
  end

  def normalized_content(message)
    message.content.to_s.unicode_normalize(:nfkc).squish
  end
end
