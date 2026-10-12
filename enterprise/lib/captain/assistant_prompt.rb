# frozen_string_literal: true

# The variable parts of the agent prompt (prompts/assistant.liquid), built from the agent and the run state:
#   instruction / global_system_instruction  the texts with every $ field written as its value and every @ tool as its function name
#   now_text                                 the one-line clock and, on the official WhatsApp channel, the reply window
#   patient_lines                            the patient name and phone, and a number only when a bound tool takes it
# The run state (prompt_state, runtime_clock, ...) is data and is not changed here; this class only chooses the text.
class Captain::AssistantPrompt
  def initialize(assistant:, context:, state:, prompt_state:)
    @assistant = assistant
    @context = context
    @state = state.to_h
    @prompt_state = prompt_state.to_h
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

    Array(@context[:runtime_tool_ids]).map(&:to_s)
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
      numbered_line(:contact, 'Patient number', contact[:id]),
      ("Conversation labels: #{labels.join(', ')}." if labels.any?),
      numbered_line(:conversation, 'Conversation number', conversation[:display_id])
    ].compact
  end

  # "Patient number: 7." when a bound tool takes that number, else nothing.
  def numbered_line(kind, label, number)
    "#{label}: #{number}." if number.present? && Captain::PromptNumbers.shown?(kind, bound_tool_ids)
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
