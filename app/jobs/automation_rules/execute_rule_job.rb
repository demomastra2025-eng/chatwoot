class AutomationRules::ExecuteRuleJob < ApplicationJob
  queue_as :scheduled_jobs

  EXECUTION_COMPLETED_TTL = 30.days.to_i
  ExecutionInProgressError = Class.new(StandardError)

  # rubocop:disable Metrics/ParameterLists
  def perform(rule_id, execution_signature, record_gid, changed_attributes = {}, trigger_message_id = nil, execution_key = nil,
              lifecycle_generation = nil)
    rule = AutomationRule.find_by(id: rule_id)
    return unless executable_rule?(rule, execution_signature, lifecycle_generation)

    record = GlobalID::Locator.locate(record_gid)
    return if record.blank? || record.account_id != rule.account_id

    trigger_message = rule.account.messages.find_by(id: trigger_message_id) if trigger_message_id.present?
    perform_once(rule, execution_key) do
      AutomationRules::ExecutionService.new(
        rule: rule,
        record: record,
        changed_attributes: changed_attributes,
        trigger_message: trigger_message,
        execution_key: execution_key
      ).perform_actions
    end
  end
  # rubocop:enable Metrics/ParameterLists

  private

  def executable_rule?(rule, execution_signature, lifecycle_generation)
    rule&.active? &&
      rule.execution_signature == execution_signature &&
      rule.lifecycle_generation == (lifecycle_generation || 1)
  end

  def perform_once(rule, execution_key)
    return yield if execution_key.blank?

    completed_key = execution_cache_key(rule, execution_key, 'completed')
    return if Redis::Alfred.get(completed_key).present?

    AutomationRule.connection_pool.with_connection do |connection|
      lock_id = advisory_lock_id(rule, execution_key)
      claimed = connection.select_value("SELECT pg_try_advisory_lock(#{lock_id})")
      raise ExecutionInProgressError, 'Automation execution is already processing' unless claimed

      begin
        if Redis::Alfred.get(completed_key).blank?
          yield
          Redis::Alfred.set(completed_key, true, ex: EXECUTION_COMPLETED_TTL)
        end
      ensure
        connection.execute("SELECT pg_advisory_unlock(#{lock_id})")
      end
    end
  end

  def advisory_lock_id(rule, execution_key)
    source = "automation-rule-execution:#{rule.account_id}:#{rule.id}:#{execution_key}"
    Digest::SHA256.hexdigest(source).first(16).to_i(16) % ((2**63) - 1)
  end

  def execution_cache_key(rule, execution_key, state)
    "automation_rule_execution:#{rule.account_id}:#{rule.id}:#{execution_key}:#{state}"
  end
end
