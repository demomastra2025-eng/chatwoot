module Enterprise::Captain::BaseTaskService
  def perform
    return { error: I18n.t('captain.copilot_limit'), error_code: 429 } unless responses_available?

    unless captain_tasks_enabled?
      return { error: I18n.t('captain.upgrade') } if ChatwootApp.chatwoot_cloud?

      return { error: I18n.t('captain.disabled') }
    end

    result = super
    increment_usage(result) if successful_result?(result)
    result
  end

  private

  def responses_available?
    return true unless ChatwootApp.chatwoot_cloud?

    account.captain_quota_available?
  end

  def successful_result?(result)
    result.is_a?(Hash) && result[:message].present? && !result[:error]
  end

  def increment_usage(result)
    Rails.logger.info("[CAPTAIN][#{self.class.name}] Incrementing response usage for account #{account.id}")
    account.increment_response_usage
    account.increment_token_usage(extract_total_tokens(result))
  end

  def extract_total_tokens(result)
    result.dig(:usage, 'total_tokens') || result.dig(:usage, :total_tokens) ||
      result.dig('usage', 'total_tokens') || result.dig('usage', :total_tokens)
  end
end
