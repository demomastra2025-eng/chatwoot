require 'securerandom'

# Converts legacy automation actions only when explicitly requested by an operator.
class Reminders::ConvertPlanActionsService
  def initialize(apply: false, output: $stdout)
    @apply = apply
    @output = output
  end

  def perform
    AutomationRule.where('actions @> ?::jsonb', [{ action_name: 'apply_touch_plan' }].to_json).find_each do |rule|
      convert_rule(rule)
    end
  end

  private

  def convert_rule(rule)
    if @apply
      rule.with_lock { rewrite_rule(rule) }
    else
      rewrite_rule(rule)
    end
  rescue ActiveRecord::RecordInvalid => e
    @output.puts "account=#{rule.account_id} rule=#{rule.id} skipped: #{e.record.errors.full_messages.join(', ')}"
  end

  def rewrite_rule(rule)
    replacements = rule.actions.map { |action| replacement_for(rule, action) }
    return if replacements.any?(&:nil?)
    return unless replacements.any?(Array)

    rule.update!(actions: replacements.flatten(1)) if @apply
  end

  def replacement_for(rule, action)
    return action unless action['action_name'] == 'apply_touch_plan'

    group = rule.account.reminder_groups.kept.find_by(id: plan_id(action['action_params']))
    if group.blank? || group.touches.blank?
      @output.puts "account=#{rule.account_id} rule=#{rule.id} skipped action=#{action['action_id']}: plan unavailable"
      return nil
    end

    mode = @apply ? 'apply' : 'dry-run'
    @output.puts "mode=#{mode} account=#{rule.account_id} rule=#{rule.id} " \
                 "apply_touch_plan=#{action['action_id']} -> create_touch_actions=#{group.touches.size}"
    group.touches.map { |step| inline_action(action, step) }
  end

  def inline_action(action, step)
    action.merge(
      'action_name' => 'create_touch',
      'action_id' => SecureRandom.uuid,
      'action_params' => [step.deep_stringify_keys.except('step_id')]
    )
  end

  def plan_id(params)
    value = params.is_a?(Array) ? params.first : params
    value = value.with_indifferent_access if value.is_a?(Hash)
    value.is_a?(Hash) ? (value[:id] || value[:reminder_group_id] || value[:touch_plan_id]) : value
  end
end
