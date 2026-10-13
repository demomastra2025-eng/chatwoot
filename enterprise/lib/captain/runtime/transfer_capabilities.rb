# frozen_string_literal: true

# One short line for the description of a colleague's transfer tool: what that colleague can DO ("book, reschedule and cancel
# appointments; look up specialists and free slots"). The routing text of the colleague says what it answers; this line lets the
# model choose by what the patient wants done. It is written with the words of the glossary of the agent texts (appointment,
# specialist, service, slot, deal), never with tool ids. A tool id that has no phrase here says nothing about a colleague (the
# notes and labels of the conversation and handoff every agent has) and is left out. So are the tools of the shared read layer
# (the FAQ and the service catalog with prices, see Captain::ToolAccess::SHARED_READ_TOOL_IDS): every agent answers those
# questions itself, so they are never a reason to transfer a conversation to a colleague.
module Captain::Runtime::TransferCapabilities
  APPOINTMENT_VERBS = {
    'create_appointment' => 'book', 'update_appointment' => 'reschedule', 'cancel_appointment' => 'cancel'
  }.freeze
  ACTIONS = {
    'create and update deals' => %w[create_deal update_deal transition_deal_stage],
    'create and update tasks' => %w[create_task update_task change_task_status]
  }.freeze
  LOOKUPS = {
    'specialists' => %w[search_scheduling_resources list_scheduling_resources get_scheduling_resource_schedule],
    'free slots' => %w[search_available_slots get_scheduling_resource_availability],
    'appointments' => %w[list_my_appointments search_appointments get_appointment],
    'deals' => %w[search_deals list_my_deals get_deal list_deal_pipelines list_deal_stages get_deal_timeline],
    'tasks' => %w[search_tasks get_task get_task_timeline],
    'clinic documents' => %w[list_captain_documents search_documentation]
  }.freeze

  module_function

  # tool_ids: the ids (names) of the colleague's tools. Blank when nothing is left to say.
  def line(tool_ids)
    ids = Array(tool_ids).map(&:to_s) - Captain::ToolAccess::SHARED_READ_TOOL_IDS
    phrases = appointment_phrases(ids) + ACTIONS.select { |_phrase, tools| tools.intersect?(ids) }.keys
    lookups = LOOKUPS.select { |_phrase, tools| tools.intersect?(ids) }.keys
    phrases << "look up #{sentence(lookups)}" if lookups.any?
    phrases.any? ? "Can: #{phrases.join('; ')}." : ''
  end

  # "book, reschedule and cancel appointments": the verbs of the appointment tools the colleague has.
  def appointment_phrases(ids)
    verbs = APPOINTMENT_VERBS.filter_map { |tool_id, verb| verb if ids.include?(tool_id) }
    verbs.any? ? ["#{sentence(verbs)} appointments"] : []
  end

  # English whatever the locale of the request is (Array#to_sentence reads the connectors from the current locale).
  def sentence(words)
    words.to_sentence(words_connector: ', ', two_words_connector: ' and ', last_word_connector: ' and ')
  end
end
