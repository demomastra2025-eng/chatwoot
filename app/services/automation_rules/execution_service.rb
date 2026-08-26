class AutomationRules::ExecutionService
  UNRESOLVED_SCHEDULE = Object.new.freeze

  attr_reader :rule, :record, :changed_attributes, :trigger_message, :execution_key

  def initialize(rule:, record:, changed_attributes: {}, trigger_message: nil, execution_key: nil)
    @rule = rule
    @record = record
    @changed_attributes = changed_attributes
    @trigger_message = trigger_message
    @execution_key = execution_key
  end

  def self.execution_key_for(event:, record:, trigger_message: nil)
    payload = {
      event_name: event.name,
      event_timestamp: event.timestamp&.utc&.iso8601(9),
      record: record.to_global_id.to_s,
      trigger_message: trigger_message&.to_global_id&.to_s,
      changed_attributes: canonicalize(event.data[:changed_attributes].to_h)
    }
    OpenSSL::Digest::SHA256.hexdigest(payload.to_json)
  end

  def self.canonicalize(value)
    case value
    when Hash
      value.to_h.stringify_keys.sort.to_h.transform_values { |nested| canonicalize(nested) }
    when Array
      value.map { |nested| canonicalize(nested) }
    else
      value
    end
  end
  private_class_method :canonicalize

  def perform
    due_at = scheduled_at
    return if due_at.equal?(UNRESOLVED_SCHEDULE)

    job_arguments = [
      rule.id,
      rule.execution_signature,
      record.to_global_id.to_s,
      changed_attributes,
      trigger_message&.id,
      execution_key || SecureRandom.uuid
    ]

    if due_at.present? && due_at > Time.current
      AutomationRules::ExecuteRuleJob.set(wait_until: due_at).perform_later(*job_arguments)
    else
      AutomationRules::ExecuteRuleJob.perform_later(*job_arguments)
    end
  end

  def perform_actions
    case record
    when Conversation
      conversation_action_service.perform
    when Scheduling::Appointment
      AutomationRules::AppointmentActionService.new(
        rule,
        rule.account,
        record,
        changed_attributes: changed_attributes,
        execution_key: execution_key
      ).perform
    when Crm::Deal
      perform_crm_actions('deal')
    when Crm::Task
      perform_crm_actions('task')
    else
      raise ArgumentError, "Unsupported automation record: #{record.class.name}"
    end
  end

  private

  def scheduled_at
    schedule = rule.execution_schedule.to_h.with_indifferent_access
    return if schedule.blank? || schedule[:timing_mode].blank? || schedule[:timing_mode] == 'immediate'

    probe = execution_schedule_probe(schedule)
    raise ArgumentError, 'Automation execution schedule is invalid' unless probe.valid?

    if probe.scheduled_at.blank?
      Rails.logger.info("Skipping automation rule #{rule.id}: execution schedule anchor is unavailable")
      return UNRESOLVED_SCHEDULE
    end

    probe.scheduled_at
  end

  def execution_schedule_probe(schedule)
    Reminder.new(
      account: rule.account,
      remindable: record,
      action_type: 'send_message',
      body: 'automation_execution',
      content_kind: 'free_text',
      timing_mode: schedule[:timing_mode],
      scheduled_at: schedule[:scheduled_at],
      relative_anchor: schedule[:relative_anchor],
      relative_offset_seconds: schedule[:relative_offset_seconds],
      relative_time_mode: schedule[:relative_time_mode],
      relative_time_of_day: schedule[:relative_time_of_day],
      timezone: schedule[:timezone].presence || account_timezone
    )
  end

  def account_timezone
    rule.account.reporting_timezone.presence || 'UTC'
  end

  def perform_crm_actions(entity_kind)
    AutomationRules::CrmActionService.new(
      rule,
      rule.account,
      record,
      entity_kind: entity_kind,
      options: { changed_attributes: changed_attributes, execution_key: execution_key }
    ).perform
  end

  def conversation_action_service
    arguments = [rule, rule.account, record]
    return AutomationRules::ActionService.new(*arguments, execution_key: execution_key) if trigger_message.blank?

    AutomationRules::ActionService.new(*arguments, trigger_message: trigger_message, execution_key: execution_key)
  end
end
