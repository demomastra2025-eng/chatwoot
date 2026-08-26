class AutomationRules::ActionRunner
  ACTION_COMPLETED_TTL = 30.days.to_i

  def initialize(rule:, account:, execution_key: nil)
    @rule = rule
    @account = account
    @execution_key = execution_key
  end

  def perform
    failures = []
    rule.actions.each_with_index do |raw_action, index|
      action = raw_action.with_indifferent_access
      next if action_completed?(action, index)

      begin
        yield(action, index)
        mark_action_completed!(action, index)
      rescue StandardError => e
        ChatwootExceptionTracker.new(e, account: account).capture_exception
        failures << e
      end
    end

    raise failures.first if failures.any? && execution_key.present?
  end

  private

  attr_reader :account, :execution_key, :rule

  def action_completed?(action, index)
    return false if execution_key.blank?

    Redis::Alfred.get(action_cache_key(action, index)).present?
  end

  def mark_action_completed!(action, index)
    return if execution_key.blank?

    Redis::Alfred.set(action_cache_key(action, index), true, ex: ACTION_COMPLETED_TTL)
  end

  def action_cache_key(action, index)
    action_key = action[:action_id].presence || "legacy-index:#{index}"
    "automation_rule_action:#{account.id}:#{rule.id}:#{execution_key}:#{action_key}:completed"
  end
end
