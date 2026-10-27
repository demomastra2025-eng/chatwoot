# frozen_string_literal: true

# A reply suggestion offers only the times its own scheduling reads returned. A time the draft names that no scheduling result of
# the run holds, and that neither the patient nor the dialog named, is named to the manager above the draft (the draft itself is
# never changed: the manager decides). In the suggestion eval of 26.10 a draft for Sezim (Байтурсынова) offered 19:00 from the
# clinic text «последняя запись 19:00» while the slot search returned 19:30 and 19:50.
#
# Only a run that searched free times (search_available_slots) is checked. A time counts as found when a source the agent read
# names it: the reads of that run (the cache of its reads, see Captain::Runtime::ToolWrapper#cache_suggestion_read_result: the
# schedule, appointments and the patient card), the patient data of its prompt (the appointment and deal summaries and data
# blocks of the # Patient block), what the agents already did in this conversation (Captain::DoneActions: the cards of earlier
# replies, so a corrected booking may name the time it replaces), the dialog and the patient's message. A knowledge or FAQ text
# is not a schedule, so a time that only such a text names is still named to the manager. A time the draft names as a bound («до
# 19:00 окон нет», «после 14:00 только при предоплате», «19:00-ге дейін») offers nothing and is not checked. A council is not
# checked: its parts read in runs of their own. A time under the name of the wrong specialist is Captain::ReplySuggestion::DraftSpecialists.
module Captain::ReplySuggestion::DraftTimes
  # 9:30, 09:30 and 09:30:00 (an ISO start); never part of a longer number or of a date.
  TIME = /(?<![\d:])([01]?\d|2[0-3]):([0-5]\d)(?::[0-5]\d)?(?![\d:])/
  # A bound before a time («до», «после», «позже», «не позднее», «раньше») or after it in Kazakh («-ге дейін», «-ден кейін»).
  BOUND_BEFORE = /(?<![[:alpha:]])(?:до|после|позже|позднее|раньше)[[:space:]]+\z/i
  BOUND_AFTER = /\A(?:-?[[:alpha:]]{2,3})?[[:space:]]*(?:дейін|кейін)(?![[:alpha:]])/i
  BOUND_WINDOW = 20
  SLOT_SEARCH_TOOL = 'search_available_slots'
  SOURCE_TOOLS = %w[
    search_available_slots get_scheduling_resource_availability get_scheduling_resource_schedule search_appointments get_appointment
    list_my_appointments get_my_contact get_contact get_appointment_provider_status
  ].freeze
  # Fields of a read that name a time which is no free time (see Scheduling::AvailableSlotSearchService#last_booking_time and
  # #last_booking_time_by_weekday).
  IGNORED_KEYS = %w[last_booking_time last_booking_time_by_weekday].freeze

  module_function

  # The times of the draft ("19:00") that the run did not find; empty when the run searched no free times.
  def unverified(draft:, context:)
    context = context.to_h
    return [] if draft.blank? || !searched_slots?(context)

    offered_times(draft) - known_times(context)
  end

  def times(text)
    text.to_s.scan(TIME).map { |hour, minute| clock(hour, minute) }.uniq
  end

  # The times of the draft that are no bound («до 19:00», «после 14:00»).
  def offered_times(text)
    offered_time_matches(text.to_s).map(&:last).uniq
  end

  # [position in the text, "09:30"] of every offered time of the text (no bound), in the order of the text.
  def offered_time_matches(text)
    text.to_enum(:scan, TIME).filter_map do
      match = Regexp.last_match
      [match.begin(0), clock(match[1], match[2])] unless bound?(text, match)
    end
  end

  def bound?(text, match)
    before = text[0...match.begin(0)].last(BOUND_WINDOW)
    after = text[match.end(0)..].to_s.first(BOUND_WINDOW)
    before.match?(BOUND_BEFORE) || after.match?(BOUND_AFTER)
  end

  def clock(hour, minute)
    format('%<hour>02d:%<minute>s', hour: hour.to_i, minute: minute)
  end

  def searched_slots?(context)
    names = Array(value(context, :captain_v2_completed_tool_names))
    names.any? { |name| Captain::Runtime::ToolFailure.canonical_name(name) == SLOT_SEARCH_TOOL }
  end

  # The times of the scheduling reads of the run, of the patient data of the prompt, of what the agents already did, of the dialog
  # and of the patient's message.
  def known_times(context)
    (read_texts(context) + prompt_texts(context) + dialog_texts(context)).flat_map { |text| times(text) }.uniq
  end

  # The results of the scheduling reads of the run.
  def read_texts(context)
    value(context, Captain::Runtime::ToolWrapper::SUGGESTION_READ_CACHE_KEY).to_h.values.filter_map do |entry|
      entry = entry.to_h.with_indifferent_access
      read_text(entry[:result]) if SOURCE_TOOLS.include?(entry[:tool].to_s)
    end
  end

  # The dialog (without the send time the platform stamps on every history message) and the patient's message.
  def dialog_texts(context)
    dialog = Array(value(context, :conversation_history)).map do |message|
      Captain::PromptClock.unstamped(Captain::Runtime::RoutingSnapshot.text_of(value(message.to_h, :content)))
    end
    dialog + [Captain::Runtime::RoutingSnapshot.text_of(value(context, :captain_v2_current_input))]
  end

  # The patient data the prompt is built from (the appointment and deal summaries and data blocks of the # Patient block, see
  # Captain::AssistantPrompt#patient_lines) and the actions the agents already did in this conversation (Captain::DoneActions).
  def prompt_texts(context)
    prompt_context = value(value(context, :state).to_h, :prompt_context)
    [prompt_context, value(context, :done_actions)].compact_blank.map { |data| read_text(data) }
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
