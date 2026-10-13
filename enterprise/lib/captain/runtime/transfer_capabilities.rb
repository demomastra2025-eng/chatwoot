# frozen_string_literal: true

# One short line for the description of a colleague's transfer tool: what that colleague can DO, read from its tool ids
# ("create, update and cancel appointment; create and update deal"). The routing text of the colleague says what it answers; this
# line lets the model choose by what the patient wants done. The tools every agent has (handoff, the FAQ, notes and labels of the
# conversation) say nothing about a colleague and are left out.
module Captain::Runtime::TransferCapabilities
  ACTION_VERBS = %w[create update cancel change transition merge assign].freeze
  LOOKUP_VERBS = %w[search get list].freeze
  SHARED_TOOL_IDS = %w[
    handoff faq_lookup resolve_conversation cancel_response add_private_note add_contact_note send_notification
    update_priority add_label_to_conversation remove_label_from_conversation get_my_contact update_my_contact
  ].freeze
  MAX_ACTIONS = 4
  MAX_LOOKUPS = 4

  module_function

  # tool_ids: the ids (names) of the colleague's tools. Blank when nothing is left to say.
  def line(tool_ids)
    pairs = Array(tool_ids).map(&:to_s).uniq.excluding(*SHARED_TOOL_IDS).filter_map { |id| split(id) }
    phrases = action_phrases(pairs) + lookup_phrases(pairs)
    phrases.any? ? "Tools: #{phrases.join('; ')}." : ''
  end

  # "create_appointment" -> ["create", "appointment"]; "list_my_appointments" -> ["list", "appointments"].
  def split(tool_id)
    verb, object = tool_id.split('_', 2)
    return if verb.blank? || object.blank? || tool_id.start_with?('mcp__')

    [verb, object.delete_prefix('my_').tr('_', ' ')]
  end

  # The verbs of one object are joined: "create, update and cancel appointment".
  def action_phrases(pairs)
    actions = pairs.select { |pair| ACTION_VERBS.include?(pair.first) }
    actions.group_by(&:last).first(MAX_ACTIONS).map { |object, group| "#{sentence(group.map(&:first).uniq)} #{object}" }
  end

  def lookup_phrases(pairs)
    objects = pairs.select { |pair| LOOKUP_VERBS.include?(pair.first) }.map(&:last).uniq.first(MAX_LOOKUPS)
    objects.any? ? ["look up #{sentence(objects)}"] : []
  end

  # English whatever the locale of the request is (Array#to_sentence reads the connectors from the current locale).
  def sentence(words)
    words.to_sentence(words_connector: ', ', two_words_connector: ' and ', last_word_connector: ' and ')
  end
end
