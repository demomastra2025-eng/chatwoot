# frozen_string_literal: true

# The successful data-changing actions that the agents did in a conversation, as the short English list "Done in this
# conversation" of the agent prompt (see Captain::AssistantPrompt). An agent that receives the conversation after a transfer, or the
# next message of the patient, reads from it what is already done: it reports an action and never repeats it.
#
# An action is recorded once, when its tool succeeded (see Captain::Runtime::OperationGuard and
# Captain::Conversation::AgentSession#finish_operation), from the arguments and the result of that tool. The labels are English; the
# values (names, titles, dates, amounts) stay as the tool returned them. A patient's data is named by field, never by value. Each
# record keeps the request it was done in (the anchor of Captain::Runtime::TaskQueue#request_scope), so the list can say which
# action answers the current message and which one is earlier.
module Captain::DoneActions
  LIMIT = 5
  TEXT_LIMIT = 220
  HEADER = 'Done in this conversation:'
  CURRENT = '(in reply to this message)'
  EARLIER = '(earlier)'
  AWAITING = 'awaiting confirmation'
  APPOINTMENT_LABELS = {
    'create_appointment' => 'Booked', 'update_appointment' => 'Rescheduled', 'cancel_appointment' => 'Cancelled appointment'
  }.freeze
  PENDING_APPOINTMENT_LABELS = {
    'create_appointment' => 'Booking requested', 'update_appointment' => 'Reschedule requested',
    'cancel_appointment' => 'Cancellation requested'
  }.freeze
  DEAL_LABELS = { 'create_deal' => 'Created deal', 'update_deal' => 'Updated deal', 'transition_deal_stage' => 'Moved deal' }.freeze
  TASK_LABELS = { 'create_task' => 'Created task', 'update_task' => 'Updated task', 'change_task_status' => 'Changed task status' }.freeze
  COMPANY_LABELS = { 'create_company' => 'Created company', 'update_company' => 'Updated company' }.freeze
  PATIENT_TOOLS = %w[update_contact update_my_contact].freeze
  PATIENT_LABEL = 'Updated patient data'
  HANDOFF_TOOL = 'handoff'
  HANDOFF_LABEL = 'Handed off to staff'

  module_function

  # The record of one successful action, or nil when the tool is not one of the actions that are listed or nothing was changed.
  # Never raises: the list is a help for the model and must never fail the tool call.
  def entry(tool_name:, arguments:, result:, request:)
    name = Captain::Runtime::ToolFailure.canonical_name(tool_name)
    facts = Captain::Runtime::ToolFailure.facts(result)
    label, text = describe(name, arguments.to_h.deep_stringify_keys, facts, pending: Captain::Runtime::ToolFailure.pending?(result))
    return if label.blank?

    { 'tool' => name, 'label' => label, 'text' => text.to_s.squish.first(TEXT_LIMIT), 'request' => request.to_s }
  rescue StandardError
    nil
  end

  # The list with the new record first, at most LIMIT records long. A record that repeats the newest one is not added twice.
  def remember(entries, entry)
    list = Array(entries)
    return list if entry.blank?
    return list.first(LIMIT) if list.first == entry

    [entry, *list].first(LIMIT)
  end

  # The list and the request that is being answered now, from the context of a run (nil when it holds no action).
  def for_run(context)
    entries = Array(context.to_h[:done_actions])
    return if entries.empty?

    { entries: entries, request: Captain::Runtime::TaskQueue.new(context).request_scope }
  end

  # The lines of the prompt: a header, then one line per action, newest first, marked as done in reply to the current message or
  # earlier. No line at all when nothing was done.
  def lines(done)
    entries = Array(done.to_h[:entries]).first(LIMIT)
    return [] if entries.empty?

    [HEADER, *entries.map { |entry| line_of(entry.to_h.stringify_keys, done[:request]) }]
  end

  def line_of(entry, request)
    mark = entry['request'].present? && entry['request'] == request ? CURRENT : EARLIER
    ["- #{[entry['label'], entry['text']].compact_blank.join(': ')}", mark].join(' ')
  end

  def handoff_entry(reason:, request:, user_message: nil)
    { 'tool' => HANDOFF_TOOL, 'label' => HANDOFF_LABEL, 'text' => quoted(reason).to_s.first(TEXT_LIMIT),
      'request' => request.to_s, 'user_message' => user_message.to_s.squish.first(500).presence }.compact
  rescue StandardError
    nil
  end

  def describe(name, arguments, facts, pending:)
    if APPOINTMENT_LABELS.key?(name)
      appointment_parts(name, facts, pending)
    elsif DEAL_LABELS.key?(name)
      [DEAL_LABELS.fetch(name), deal_text(name, facts)]
    elsif TASK_LABELS.key?(name)
      [TASK_LABELS.fetch(name), quoted(facts['title'])]
    elsif COMPANY_LABELS.key?(name)
      [COMPANY_LABELS.fetch(name), quoted(facts['name'])]
    elsif PATIENT_TOOLS.include?(name)
      patient_parts(arguments)
    end
  end

  # An update that asked for what the appointment already has, and a booking that exists already, changed nothing (the statuses of
  # Captain::ToolResult::NO_CHANGE_STATUSES): the earlier record of the action stays the one that tells it. A change that the provider
  # has not confirmed yet is a request, never a done action.
  def appointment_parts(name, facts, pending)
    return if Captain::ToolResult::NO_CHANGE_STATUSES.include?(facts['status'].to_s)

    if pending
      moment = moment_of(facts['requested_local_date'] || facts['local_date'], facts['requested_local_time'] || facts['local_time'])
      return [PENDING_APPOINTMENT_LABELS.fetch(name), [facts['doctor_name'], moment, AWAITING].compact_blank.join(', ')]
    end

    moment = moment_of(facts['local_date'], facts['local_time'])
    moment = "now #{moment}" if moment && name == 'update_appointment'
    [APPOINTMENT_LABELS.fetch(name), [facts['doctor_name'], moment].compact_blank.join(', ')]
  end

  def deal_text(name, facts)
    parts = [quoted(facts['title']), ([facts['amount'], facts['currency']].compact_blank.join(' ').presence)]
    parts << "stage #{quoted(facts.dig('current_stage', 'name'))}" if name == 'transition_deal_stage' && facts.dig('current_stage', 'name').present?
    parts.compact_blank.join(', ')
  end

  # The fields that were changed, by name: a name, a phone number or an IIN is not written into the prompt again.
  def patient_parts(arguments)
    fields = arguments.reject { |_field, value| value.blank? }.keys.map { |field| field.to_s.tr('_', ' ') }
    [PATIENT_LABEL, fields.join(', ')] if fields.any?
  end

  # "Thu 15.10.2026 11:00" from the local date and time that the scheduling tools return.
  def moment_of(date, time)
    day = Date.strptime(date.to_s, '%d.%m.%Y')
    [day.strftime('%a'), date, time].compact_blank.join(' ')
  rescue ArgumentError
    [date, time].compact_blank.join(' ').presence
  end

  def quoted(value)
    text = value.to_s.squish
    "«#{text}»" if text.present?
  end
end
