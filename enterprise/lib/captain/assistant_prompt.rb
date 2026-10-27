# frozen_string_literal: true

# Builds the compact variables of assistant.liquid:
#   instruction, global_system_instruction,  the clinic instruction, the shared rules and the clinic context (the "# Clinic" block,
#   clinic_context                           Account#captain_clinic_context) with $ field values and @ tool names resolved
#   now_text                                 the one-line clock, the send time of the patient's last message when it was not sent
#                                            today, after midnight the night line and, on the official WhatsApp channel, the reply window
#   patient_lines                            the patient name and phone, an ID only when a bound tool takes it, the appointment
#                                            and deal summaries that the clinic instruction does not place itself, and the list of
#                                            what the agents already did in this conversation (Captain::DoneActions)
# The run state (prompt_state, runtime_clock, ...) is data and is not changed here; this class only chooses the text.
#
# part: true is the run of a council part. The owner of a part gets its own tools except the ones that change who controls the
# conversation (Captain::Runtime::PartTools), so a mention or a number of such a tool is written as if the tool were not bound.
class Captain::AssistantPrompt
  # The summaries of the run state and the label each one has in the Patient block.
  SUMMARY_LABELS = { appointment: 'Appointments', deal: 'Deals' }.freeze

  # done: the actions the agents already did in this conversation and the request being answered (Captain::DoneActions.for_run).
  # preload: what a reply suggestion read at its start instead of with tools (Captain::ReplySuggestion::PatientPreload).
  def initialize(assistant:, context:, state:, prompt_state:, part: false, suggestion: false, done: nil, preload: nil) # rubocop:disable Metrics/ParameterLists
    @assistant = assistant
    @context = context
    @state = state.to_h
    @prompt_state = prompt_state.to_h
    @part = part
    @suggestion = suggestion
    @done = done
    @preload = preload.to_h
  end

  def variables
    texts = @assistant.resolve_prompt_texts(
      { instruction: @context[:instruction], global_system_instruction: @context[:global_system_instruction],
        clinic_context: @context[:clinic_context] },
      @prompt_state, bound_tool_ids: bound_tool_ids, time_zone: time_zone
    )
    variables = texts.merge(now_text: now_text, patient_lines: patient_lines)
    return variables unless @suggestion

    variables.merge(operator_language: operator_language, booking_search: booking_search?, faq_lines: faq_lines)
  end

  private

  # The language the clinic operator reads: the notes of a reply suggestion (operator_note) are written in it.
  def operator_language
    @assistant.account&.locale_english_name.presence || 'russian'
  end

  # A reply suggestion of an agent that searches free times also has the booking search (Captain::Assistant#filter_agent_tools), and
  # the rules send it there first.
  def booking_search?
    Array(bound_tool_ids).include?(Captain::Assistant::SLOT_SEARCH_TOOL_ID)
  end

  # The tools of this run; nil when the context does not say (every @ mention is then its function name, no number is shown).
  def bound_tool_ids
    return unless @context.key?(:runtime_tool_ids)

    Captain::Runtime::PartTools.effective_tool_ids(
      @context[:runtime_tool_ids],
      part: @part || @suggestion
    )
  end

  def time_zone
    @time_zone ||= Captain::PromptClock.zone_for(
      @state[:runtime_clock].to_h.with_indifferent_access[:timezone], @assistant.account&.reporting_timezone
    )
  end

  def now_text
    return '' if @state.blank?

    [
      Captain::PromptClock.now_line(@state[:runtime_clock]),
      Captain::PromptClock.message_line(@state[:runtime_clock]),
      Captain::PromptClock.night_line(@state[:runtime_clock]),
      Captain::PromptClock.reply_window_line(@state[:reply_window], time_zone: time_zone),
      Captain::PatientLanguage.line(@context[:patient_language])
    ].compact.join("\n")
  end

  def patient_lines
    contact = section(:contact)
    conversation = section(:conversation)
    who = [one_line(contact[:name]), one_line(contact[:phone_number])].compact_blank.join(', ')
    labels = Array(conversation[:label_list]).map { |label| one_line(label) }.compact_blank

    [
      ("#{who}." if who.present?),
      numbered_line(:contact, 'Patient ID', contact[:id]),
      ("Conversation labels: #{labels.join(', ')}." if labels.any?),
      numbered_line(:conversation, 'Conversation ID', conversation[:display_id]),
      *unplaced_summary_lines,
      *preload_lines,
      *Captain::DoneActions.lines(@done)
    ].compact
  end

  # The FAQ answers close to the patient's latest message that the suggestion found before the first model call (Captain::ReplySuggestion::
  # FaqPreload), as labelled reference text for the template. Never part of the Patient block: they are the clinic's texts, no patient data.
  def faq_lines
    Array(@preload[:faq]).map do |match|
      answer = Captain::EncodingNormalizer.string(match[:answer].to_s).strip.gsub(/\n+/, "\n  ")
      "- Q: #{Captain::EncodingNormalizer.string(match[:question].to_s).strip}\n  A: #{answer}\n  (match #{match[:score]})"
    end
  end

  # What the suggestion read of the patient when it started, for an agent that has the tool that would have read it.
  def preload_lines
    return [] unless @suggestion && @preload.present?

    [patient_card_line, appointments_line].compact
  end

  def patient_card_line
    card = @preload[:card]
    return if card.blank? || !tool_bound?(Captain::ReplySuggestion::PatientPreload::CARD_TOOL)

    "Patient card on file (data; get_my_contact returns the same): #{JSON.generate(card)}."
  end

  def appointments_line
    return unless @preload.key?(:appointments) && tool_bound?(Captain::ReplySuggestion::PatientPreload::APPOINTMENTS_TOOL)

    entries = Array(@preload[:appointments])
    label = 'Upcoming appointments of the patient and of the patients on the same phone'
    return "#{label} (data): none." if entries.empty?

    ["#{label}, soonest first (data): #{JSON.generate(entries.map { |entry| appointment_row(entry) })}.",
     other_patient_note(entries), unlisted_appointments_note(entries)].compact.join(' ')
  end

  def other_patient_note(entries)
    return unless entries.any? { |entry| entry[:for] }

    'An entry with `for` is another patient of this phone: to change or cancel it find it first with search_appointments.'
  end

  def unlisted_appointments_note(entries)
    more = @preload[:appointments_total].to_i - entries.size
    "#{more} more are not listed: list_my_appointments gives them." if more.positive?
  end

  # The id of an appointment only when a tool bound for the run takes it (Captain::PromptNumbers) and the agent's own tools act on it.
  def appointment_row(entry)
    row = entry.except(:own, :for)
    row = row.except(:id) unless entry[:own] && Captain::PromptNumbers.shown?(:appointment, bound_tool_ids)
    entry[:own] ? row : { for: entry[:for] }.merge(row)
  end

  def tool_bound?(tool_id)
    Array(bound_tool_ids).include?(tool_id)
  end

  # "Patient ID: 7." when a bound tool takes that ID, else nothing.
  def numbered_line(kind, label, number)
    "#{label}: #{number}." if number.present? && Captain::PromptNumbers.shown?(kind, bound_tool_ids)
  end

  # A summary the agent has selected as context but the clinic instruction does not write with a $ reference would reach the model
  # nowhere else, so it is one line here. A reference that is made renders the summary inside the instruction, once. Only the clinic
  # instruction counts: a $ reference in the shared rules is not resolved by itself (resolve_prompt_texts reads the fields of the
  # instruction and of the clinic context), and the clinic context may link only contact fields (AccountCaptainClinicContext).
  def unplaced_summary_lines
    placed = Captain::ContextFields.extract_field_ids_from_text(@context[:instruction])
    summaries = @prompt_state[:context_summaries].to_h

    SUMMARY_LABELS.filter_map do |scope, label|
      next if placed.include?("#{scope}.summary")

      text = Captain::PromptSummaryText.render(summaries[scope] || summaries[scope.to_s], time_zone: time_zone, bound_tool_ids: bound_tool_ids)
      "#{label}: #{text}." if text.present?
    end
  end

  # The data of a record. With an explicit prompt context it is the filtered copy of the run; a bare state is read as it is.
  def section(name)
    source = @state.key?(:prompt_context) ? @prompt_state : @state
    source[name].to_h.with_indifferent_access
  end

  def one_line(value)
    Captain::EncodingNormalizer.string(value.to_s).squish
  end
end
