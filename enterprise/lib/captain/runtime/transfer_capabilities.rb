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

  # Only a new action justifies routing. Registry risk is not a write flag:
  # read tools may have high risk, so identify action ids from the tool registry.
  WRITE_TOOL_IDS = (%w[create_appointment update_appointment cancel_appointment] + ACTIONS.values.flatten).freeze
  WRITE_PREFIX = /\A(?:create|update|cancel|change|transition|complete|add|remove|send|edit|assign|resolve|merge|delete|deactivate|reactivate)_/

  def write_tool?(id)
    return false if id == 'handoff'

    WRITE_TOOL_IDS.include?(id) || (id.match?(WRITE_PREFIX) && Captain::ToolRegistry.definition_for(id).present?)
  end

  def read_only_routing?(source, target = nil)
    suggestion_routing?(source) || suggestion_routing?(target)
  end

  def suggestion_routing?(agent)
    (agent.respond_to?(:read_only_tools?) && agent.read_only_tools?) ||
      (agent.respond_to?(:suggestion_tools?) && agent.suggestion_tools?)
  end

  def configured_tool_ids_for(agent)
    return Array(agent.configured_tool_ids).map(&:to_s) if agent.respond_to?(:configured_tool_ids)

    Array(agent.tool_ids).map(&:to_s)
  end

  def distinct_routing_domain?(source, target)
    return false unless source.respond_to?(:routing_description) && target.respond_to?(:routing_description)

    source_desc = source.routing_description.to_s.strip
    target_desc = target.routing_description.to_s.strip
    source_desc.present? && target_desc.present? && source_desc != target_desc
  end

  def specialist_domain?(source, target)
    return false unless target.respond_to?(:routing_description)

    target_desc = target.routing_description.to_s.strip
    source_desc = source.respond_to?(:routing_description) ? source.routing_description.to_s.strip : ''
    target_desc.present? && target_desc != source_desc
  end

  def useful?(source, target)
    if read_only_routing?(source, target)
      source_cfg = configured_tool_ids_for(source)
      target_cfg = configured_tool_ids_for(target)
      return true if (target_cfg - source_cfg).any? { |id| write_tool?(id) }

      return specialist_domain?(source, target)
    end

    source_ids = Array(source.tool_ids).map(&:to_s)
    target_ids = Array(target.tool_ids).map(&:to_s)
    return true if (target_ids - source_ids).any? { |id| write_tool?(id) }

    target_ids.any? { |id| write_tool?(id) } && distinct_routing_domain?(source, target)
  end

  def actions(source, target)
    phrases = write_phrases(source, target)
    phrases = write_phrases(Struct.new(:tool_ids).new([]), target) if phrases.empty? && distinct_routing_domain?(source, target)
    phrases.join('; ')
  end

  def write_phrases(source, target)
    target_ids = read_only_routing?(source, target) ? configured_tool_ids_for(target) : Array(target.tool_ids).map(&:to_s)
    source_ids = read_only_routing?(source, target) ? configured_tool_ids_for(source) : Array(source.tool_ids).map(&:to_s)
    ids = (target_ids - source_ids).select { |id| write_tool?(id) }
    appointment_ids = ids & APPOINTMENT_VERBS.keys
    phrases = [line(appointment_ids).delete_prefix('Can: ').delete_suffix('.')].compact_blank
    phrases + (ids - appointment_ids).filter_map { |id| Captain::ToolRegistry.definition_for(id)&.title&.downcase }
  end

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
