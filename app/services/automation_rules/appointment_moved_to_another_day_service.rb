# A visit moved to another calendar day. What was asked or planned for the old date no longer stands for the new one:
#   - a confirmation question that is still open (the patient has not answered it) is closed, so that an answer to the old
#     message cannot confirm the new date;
#   - the "appointment created" rules plan the reminders that are timed from the visit (the day before, two hours before) once, when
#     the booking is made, and a reminder that already went out for the old date is finished. Each such action is planned again
#     for the new date, the way it is planned for a new booking, unless it still has a reminder to send (that one follows the
#     visit by itself), so that nothing goes out twice for one date.
class AutomationRules::AppointmentMovedToAnotherDayService
  VISIT_ANCHORS = Reminders::MissedAutomationTouchPolicy::APPOINTMENT_ANCHORS
  TERMINAL_STATUSES = %w[cancelled completed no_show].freeze
  REASON = 'appointment_moved_to_another_day'.freeze

  attr_reader :account, :appointment, :rules

  def initialize(account:, appointment:, rules:)
    @account = account
    @appointment = appointment
    @rules = rules
  end

  def perform
    expire_open_confirmation_requests
    return if appointment.status.in?(TERMINAL_STATUSES)

    rules.each { |rule| plan_again(rule) }
  end

  private

  # Only a question that reached the patient: one that was not delivered yet is refreshed with the new date when it is sent.
  def expire_open_confirmation_requests
    ConfirmationRequest.pending.button_only_response.where(account_id: account.id, subject: appointment)
                       .where.not(delivery_message_id: nil).find_each do |request|
      request.update!(
        status: 'expired', resolved_at: Time.current, resolution_source: 'system',
        resolution_metadata: request.resolution_metadata.to_h.merge('reason' => REASON)
      )
    end
  end

  def plan_again(rule)
    touches = AutomationRules::TouchActionService.new(rule: rule, account: account, record: appointment, entity_kind: 'appointment')
    actions = visit_timed_touch_actions(rule).reject { |action| touches.touch_pending?(action[:action_id]) }
    return if actions.empty?

    actions.each { |action| retire_finished_enrollment(rule, action[:action_id]) }
    AutomationRules::AppointmentActionService.new(rule, account, appointment).perform(actions: actions)
  end

  def visit_timed_touch_actions(rule)
    Array(rule.actions).map(&:with_indifferent_access).select do |action|
      params = action[:action_params]
      params = params.first if params.is_a?(Array)
      action[:action_name] == 'create_touch' && params.is_a?(Hash) &&
        params[:timing_mode].to_s == 'relative' && VISIT_ANCHORS.include?(params[:relative_anchor].to_s)
    end
  end

  # A deferred action keeps one enrollment per rule action and record, also after it has delivered. The finished one stood for the
  # old date; without retiring it the action could never be planned for the new date.
  def retire_finished_enrollment(rule, action_id)
    account.touch_plan_enrollments.where(
      automation_rule: rule, source_action_id: action_id.to_s, remindable: appointment, status: 'completed'
    ).find_each do |enrollment|
      enrollment.with_lock { enrollment.cancel!(reason: REASON) if enrollment.completed? }
    end
  end
end
