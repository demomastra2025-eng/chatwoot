# frozen_string_literal: true

class AutomationRules::CalendarNotificationAdoption
  Result = Struct.new(:errors, keyword_init: true) do
    def success?
      errors.empty?
    end
  end

  def initialize(rule)
    @rule = rule
  end

  def perform
    errors = validation_errors
    return Result.new(errors: errors) if errors.any?

    rule.update!(calendar_managed: true)
    Result.new(errors: [])
  rescue ActiveRecord::RecordInvalid
    Result.new(errors: ['INVALID_RULE'])
  end

  private

  attr_reader :rule

  def validation_errors
    precondition = adoption_precondition_error
    return [precondition] if precondition

    errors = touch_actions.flat_map { |action| validate_touch_action(action) }
    errors << 'INVALID_RULE' unless condition_values_valid?
    errors << 'INVALID_RULE' unless rule.valid?
    errors.uniq
  end

  def adoption_precondition_error
    return 'ALREADY_MANAGED' if rule.calendar_managed?
    return 'APPOINTMENT_EVENT_REQUIRED' unless rule.appointment_event?
    return 'MESSAGE_ACTION_REQUIRED' if touch_actions.empty? || touch_actions.length != Array(rule.actions).length
  end

  def touch_actions
    @touch_actions ||= Array(rule.actions).select { |action| action['action_name'] == 'create_touch' }
  end

  def condition_values_valid?
    conditions = Array(rule.conditions)
    conditions.present? && conditions.all? do |condition|
      condition['filter_operator'].in?(%w[is_present is_not_present]) || Array(condition['values']).any?(&:present?)
    end
  end

  def validate_touch_action(action)
    params_list = action['action_params']
    params_list = [params_list] unless params_list.is_a?(Array)
    return ['MESSAGE_ACTION_REQUIRED'] if params_list.empty?

    params_list.flat_map { |params| validate_touch(params) }
  end

  def validate_touch(params)
    return ['MESSAGE_ACTION_REQUIRED'] unless params.is_a?(Hash)

    inbox = rule.account.inboxes.find_by(id: params['target_inbox_id'])
    return ['WHATSAPP_REQUIRED'] unless inbox&.whatsapp? && inbox.channel.present?

    errors = []
    errors << 'SEND_PLAN_REQUIRED' unless send_plan_valid?(params)
    errors << 'MESSAGE_ACTION_REQUIRED' unless message_action_valid?(params)
    errors.concat(validate_content(params, inbox))
    errors
  end

  def send_plan_valid?(params)
    params['timing_mode'] == 'relative' &&
      params['relative_anchor'].in?(%w[touch.created_at appointment.starts_at appointment.ends_at]) &&
      params['relative_offset_seconds'].to_s.match?(/\A-?\d+\z/)
  end

  def message_action_valid?(params)
    params['repeat_mode'].to_s == 'once' && params['action_type'].to_s == 'send_message'
  end

  def validate_content(params, inbox)
    return params['body'].present? ? [] : ['MESSAGE_TEXT_REQUIRED'] if params['content_kind'] == 'free_text'
    return ['APPROVED_TEMPLATE_REQUIRED'] unless params['content_kind'] == 'channel_template'

    validate_template(params['template_params'].to_h, inbox)
  end

  def validate_template(template, inbox)
    found = Array(inbox.channel.message_templates).find do |item|
      item['name'] == template['name'] && item['language'] == template['language']
    end
    found && found['status'].to_s.upcase == 'APPROVED' ? [] : ['APPROVED_TEMPLATE_REQUIRED']
  end
end
