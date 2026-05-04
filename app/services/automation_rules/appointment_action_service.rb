class AutomationRules::AppointmentActionService
  def initialize(rule, account, appointment, options = {})
    @rule = rule
    @account = account
    @appointment = appointment
    @changed_attributes = options[:changed_attributes]
    Current.executed_by = rule
  end

  def perform
    @rule.actions.each do |action|
      action = action.with_indifferent_access
      begin
        send(action[:action_name], action[:action_params])
      rescue StandardError => e
        ChatwootExceptionTracker.new(e, account: @account).capture_exception
      end
    end
  ensure
    Current.reset
  end

  private

  def send_webhook_event(webhook_url)
    payload = @appointment.automation_webhook_data.merge(event: "automation_event.#{@rule.event_name}")
    payload[:changed_attributes] = formatted_changed_attributes if formatted_changed_attributes.present?
    WebhookJob.perform_later(webhook_url[0], payload)
  end

  def change_appointment_status(action_params)
    mutate_appointment!(status: normalize_action_param(action_params, 'change_appointment_status'))
  end

  def cancel_appointment_payment(_action_params)
    unless @account.feature_enabled?('scheduling_finance')
      raise Scheduling::Error.new(
        code: 'FEATURE_DISABLED',
        message: 'Scheduling finance is not enabled for this account',
        status: :forbidden
      )
    end

    @appointment = Scheduling::Appointments::FinanceSyncService.new(
      appointment: @appointment,
      actor: nil
    ).cancel_all!
  end

  def apply_touch_plan(action_params)
    touch_action_service.apply_touch_plan(action_params)
  end

  def create_touch(action_params)
    touch_action_service.create_touch(action_params)
  end

  def cancel_touches(action_params)
    touch_action_service.cancel_touches(action_params)
  end

  def formatted_changed_attributes
    return if @changed_attributes.blank?

    @changed_attributes.map do |key, value|
      { key => { previous_value: value[0], current_value: value[1] } }
    end
  end

  def mutate_appointment!(params)
    @appointment = Scheduling::Appointments::UpsertService.new(
      account: @account,
      params: params,
      appointment: @appointment,
      actor: nil
    ).perform
  end

  def normalize_action_param(action_params, action_name)
    value = Array(action_params).first.to_s.strip
    raise ArgumentError, "#{action_name} requires a value" if value.blank?

    value
  end

  def touch_action_service
    @touch_action_service ||= AutomationRules::TouchActionService.new(
      rule: @rule,
      account: @account,
      record: @appointment,
      entity_kind: 'appointment'
    )
  end
end
