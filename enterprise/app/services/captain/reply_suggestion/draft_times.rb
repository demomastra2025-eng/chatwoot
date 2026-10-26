# frozen_string_literal: true

# A reply suggestion offers only the times its own scheduling reads returned. A time the draft names that no scheduling result of
# the run holds, and that neither the patient nor the dialog named, is named to the manager above the draft (the draft itself is
# never changed: the manager decides). In the suggestion eval of 26.10 a draft for Sezim (Байтурсынова) offered 19:00 from the
# clinic text «последняя запись 19:00» while the slot search returned 19:30 and 19:50.
#
# Only a run that searched free times (search_available_slots) is checked, and only the reads of that run count (the cache of its
# reads, see Captain::Runtime::ToolWrapper#cache_suggestion_read_result): the reads of the schedule, of appointments and of the
# patient card. A knowledge or FAQ text is not a schedule, so a time that only such a text names is still named to the manager.
# A council is not checked: its parts read in runs of their own.
module Captain::ReplySuggestion::DraftTimes
  # 9:30, 09:30 and 09:30:00 (an ISO start); never part of a longer number or of a date.
  TIME = /(?<![\d:])([01]?\d|2[0-3]):([0-5]\d)(?::[0-5]\d)?(?![\d:])/
  SLOT_SEARCH_TOOL = 'search_available_slots'
  SOURCE_TOOLS = %w[
    search_available_slots get_scheduling_resource_availability get_scheduling_resource_schedule search_appointments get_appointment
    list_my_appointments get_my_contact get_contact get_appointment_provider_status
  ].freeze
  # Fields of a read that name a time which is no free time (see Scheduling::AvailableSlotSearchService#last_booking_time).
  IGNORED_KEYS = %w[last_booking_time].freeze

  module_function

  # The times of the draft ("19:00") that the run did not find; empty when the run searched no free times.
  def unverified(draft:, context:)
    context = context.to_h
    return [] if draft.blank? || !searched_slots?(context)

    times(draft) - known_times(context)
  end

  def times(text)
    text.to_s.scan(TIME).map { |hour, minute| format('%<hour>02d:%<minute>s', hour: hour.to_i, minute: minute) }.uniq
  end

  def searched_slots?(context)
    names = Array(value(context, :captain_v2_completed_tool_names))
    names.any? { |name| Captain::Runtime::ToolFailure.canonical_name(name) == SLOT_SEARCH_TOOL }
  end

  # The times of the scheduling reads of the run, of the patient's message and of the dialog (without the send time the platform
  # stamps on every history message).
  def known_times(context)
    reads = value(context, Captain::Runtime::ToolWrapper::SUGGESTION_READ_CACHE_KEY).to_h.values.filter_map do |entry|
      entry = entry.to_h.with_indifferent_access
      read_text(entry[:result]) if SOURCE_TOOLS.include?(entry[:tool].to_s)
    end
    dialog = Array(value(context, :conversation_history)).map do |message|
      Captain::PromptClock.unstamped(Captain::Runtime::RoutingSnapshot.text_of(value(message.to_h, :content)))
    end
    current = Captain::Runtime::RoutingSnapshot.text_of(value(context, :captain_v2_current_input))
    (reads + dialog + [current]).flat_map { |text| times(text) }.uniq
  end

  def value(hash, key)
    hash.key?(key) ? hash[key] : hash[key.to_s]
  end

  # The text of a read without the fields that name a time and are no free time (the last booking time of the clinic).
  def read_text(result)
    data = result.is_a?(String) && result.lstrip.start_with?('{', '[') ? JSON.parse(result) : result
    return data.to_s if data.is_a?(String)

    JSON.generate(without_ignored(data))
  rescue StandardError
    result.to_s
  end

  def without_ignored(data)
    case data
    when Hash then data.each_with_object({}) { |(key, item), kept| kept[key] = without_ignored(item) unless IGNORED_KEYS.include?(key.to_s) }
    when Array then data.map { |item| without_ignored(item) }
    else data
    end
  end
end
