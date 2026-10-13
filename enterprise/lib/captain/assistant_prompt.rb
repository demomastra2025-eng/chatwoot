# frozen_string_literal: true

# The variable parts of the agent prompt (prompts/assistant.liquid), built from the agent and the run state:
#   instruction / global_system_instruction  the texts with every $ field written as its value and every @ tool as its function name
#   now_text                                 the one-line clock (after midnight with the night line) and, on the official WhatsApp channel,
#                                            the reply window
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
  def initialize(assistant:, context:, state:, prompt_state:, part: false, done: nil)
    @assistant = assistant
    @context = context
    @state = state.to_h
    @prompt_state = prompt_state.to_h
    @part = part
    @done = done
  end

  def variables
    texts = @assistant.resolve_prompt_texts(
      { instruction: @context[:instruction], global_system_instruction: @context[:global_system_instruction] },
      @prompt_state, bound_tool_ids: bound_tool_ids, time_zone: time_zone
    )
    texts.merge(now_text: now_text, patient_lines: patient_lines)
  end

  private

  # The tools of this run; nil when the context does not say (every @ mention is then its function name, no number is shown).
  def bound_tool_ids
    return unless @context.key?(:runtime_tool_ids)

    ids = Array(@context[:runtime_tool_ids]).map(&:to_s)
    @part ? ids - Captain::Runtime::PartTools.withheld_tool_ids : ids
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
      Captain::PromptClock.night_line(@state[:runtime_clock]),
      Captain::PromptClock.reply_window_line(@state[:reply_window], time_zone: time_zone)
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
      *Captain::DoneActions.lines(@done)
    ].compact
  end

  # "Patient ID: 7." when a bound tool takes that ID, else nothing.
  def numbered_line(kind, label, number)
    "#{label}: #{number}." if number.present? && Captain::PromptNumbers.shown?(kind, bound_tool_ids)
  end

  # A summary the agent has selected as context but the clinic instruction does not write with a $ reference would reach the model
  # nowhere else, so it is one line here. A reference that is made renders the summary inside the instruction, once. Only the clinic
  # instruction counts: a $ reference in the shared rules is not resolved by itself (resolve_prompt_texts reads the fields of the
  # instruction).
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
