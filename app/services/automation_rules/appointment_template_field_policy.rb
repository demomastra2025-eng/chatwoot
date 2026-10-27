# frozen_string_literal: true

class AutomationRules::AppointmentTemplateFieldPolicy
  def initialize(rule:)
    @rule = rule
  end

  def errors
    return [] unless should_check?

    Scheduling::TemplateFieldFillStats.new(account: rule.account, field_ids: current_fields.keys, rule: rule)
                                      .perform.filter_map do |stat|
      next unless stat[:blocking]

      I18n.t('appointment_notifications.empty_field',
             field: current_fields[stat[:field_id]], share: (stat[:share] * 100).round)
    end
  end

  private

  attr_reader :rule

  def should_check?
    return false unless rule.appointment_event? && rule.active? && rule.account.present?
    return false if current_fields.empty?
    return true unless rule.persisted?

    rule.will_save_change_to_active? || reference_set_changed?
  end

  def reference_set_changed?
    current_fields.keys.sort != stored_fields.keys.sort
  end

  def current_fields
    @current_fields ||= references(rule.actions)
  end

  def stored_fields
    @stored_fields ||= references(rule.send(:actions_in_database))
  end

  def references(action_list)
    Array(action_list).each_with_object({}) do |action, refs|
      next unless action['action_name'] == 'create_touch'

      params = action['action_params']
      params = params.first if params.is_a?(Array)
      next unless params.is_a?(Hash)

      [params['body'], params['template_params']].each do |value|
        value.to_s.scan(FieldReferences::RendererService::FIELD_REFERENCE_REGEX) do |title, field_id|
          refs[field_id] = title if field_id.start_with?('appointment.')
        end
      end
    end
  end
end
