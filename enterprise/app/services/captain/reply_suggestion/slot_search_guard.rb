# frozen_string_literal: true

# A booking or a move that a reply suggestion prepares starts at a time that the slot search of the same run returned for that
# specialist. In the suggestion eval of 26.10 an agent prepared a booking at 14:20 for a specialist whose search returned 14:30 and
# later (the patient had asked for 14:20), and the card would have booked a time the schedule does not have. The check is on the call,
# before the card exists: the answer names the exact search to make, and the same call after that search is prepared as usual (a
# refused call claims nothing, see Captain::Runtime::ToolWrapper#pre_execution_error).
#
# It guards create_appointment and update_appointment with a new start. What the run read is Captain::ReplySuggestion::SearchedSlots.
# A call that cannot be resolved here (an unknown specialist, an unreadable time, a move without the appointment id) is not refused:
# the validation of the card reports it. An error of the check itself never blocks a call.
class Captain::ReplySuggestion::SlotSearchGuard
  GUARDED_TOOLS = %w[create_appointment update_appointment].freeze
  FAILURE_REASON = 'slot_not_searched'
  MESSAGE = 'NOT prepared: the start %<time>s on %<date>s of %<name>s (resource_id %<resource_id>d) was not returned by ' \
            'search_available_slots in this run, so it is not known to be free. Call search_available_slots with resource_ids ' \
            '[%<resource_id>d] and from = to = %<exact>s (that exact time), then call this tool again with the start it returns. ' \
            'If that search returns no start, this time is not free: say so to the patient and offer the nearest free times from ' \
            'a search of that day.'

  # The failure to answer the agent with, or nil when the call may go on.
  def self.refusal(tool_name:, arguments:, context:)
    new(tool_name, arguments, context).refusal
  end

  def initialize(tool_name, arguments, context)
    @tool_name = tool_name.to_s
    @arguments = arguments.to_h.deep_symbolize_keys
    @context = context.to_h
  end

  def refusal
    return unless GUARDED_TOOLS.include?(@tool_name) && @arguments[:starts_at].present?

    resource, starts_at = target
    return if resource.nil? || starts_at.nil?
    return if Captain::ReplySuggestion::SearchedSlots.new(@context).returned?(
      resource_id: resource.id, starts_at: starts_at, timezone: zone(resource)
    )

    failure(resource, starts_at.in_time_zone(zone(resource)))
  rescue StandardError => e
    Rails.logger.warn("[CAPTAIN][SlotSearchGuard] skipped error_class=#{e.class.name}")
    nil
  end

  private

  def target
    resource, current_start = @tool_name == 'update_appointment' ? move_target : [specialist(@arguments[:resource_id]), nil]
    return unless resource

    starts_at = Captain::Tools::Agent::AppointmentTimeInput.parse(@arguments[:starts_at], timezone: zone(resource), field_name: 'starts_at')
    return [resource, nil] if current_start && current_start.to_i == starts_at.to_i

    [resource, starts_at]
  rescue Scheduling::Error
    nil
  end

  # The specialist of a move (the new one when the call names it, else the one of the appointment) and the start it has now: a move to
  # the start it already has changes nothing and needs no search.
  def move_target
    appointment = account&.scheduling_appointments&.find_by(id: @arguments[:appointment_id]) if @arguments[:appointment_id].present?
    return unless appointment

    [specialist(@arguments[:resource_id].presence || appointment.resource_id), appointment.starts_at]
  end

  def specialist(resource_id)
    account&.scheduling_resources&.find_by(id: resource_id) if resource_id.present?
  end

  def account
    return @account if defined?(@account)

    state = (@context[:state] || @context['state']).to_h.with_indifferent_access
    @account = Account.find_by(id: state[:account_id])
  end

  def zone(resource)
    Captain::Tools::Agent::AppointmentTimeInput.timezone(resource_timezone: resource.timezone, account_timezone: account&.reporting_timezone)
  end

  def failure(resource, local)
    exact = local.strftime('%Y-%m-%dT%H:%M')
    Captain::ToolResult.failure(
      error: format(MESSAGE, time: local.strftime('%H:%M'), date: local.strftime('%Y-%m-%d'), name: resource.name,
                            resource_id: resource.id, exact: exact),
      data: { code: FAILURE_REASON, resource_id: resource.id, starts_at: exact, next_tool: 'search_available_slots' },
      retryable: true,
      audit: { failure_stage: 'tool_arguments', failure_reason: FAILURE_REASON, tool_name: @tool_name, mutation_executed: false,
               provider_call_blocked: true }
    )
  end
end
