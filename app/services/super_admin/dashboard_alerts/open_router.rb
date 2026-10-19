# frozen_string_literal: true

# The OpenRouter key and credits, as the last key check says (Llm::OpenRouterKeyHealth keeps it in the cache). Nothing is
# asked of OpenRouter here: a key that was never checked, or whose credits cannot be read, is not a problem to show.
class SuperAdmin::DashboardAlerts::OpenRouter < SuperAdmin::DashboardAlerts::Check
  # The credits are «low» when this share of the topped-up sum is left
  LOW_CREDITS_SHARE = 0.1
  # What the key check can say that needs action: status => severity
  PROBLEMS = {
    'invalid' => :danger, 'expired' => :danger, 'credits_exhausted' => :danger, 'key_limit_exhausted' => :danger,
    'missing' => :warning, 'unavailable' => :warning
  }.freeze

  def alerts
    health = Llm::OpenRouterKeyHealth.metadata.to_h.with_indifferent_access
    status = health[:status].to_s
    return [problem_alert(status, PROBLEMS.fetch(status))] if PROBLEMS.key?(status)
    return [problem_alert('credits_low', :warning)] if credits_low?(health[:credits].to_h.with_indifferent_access)

    []
  end

  private

  def problem_alert(status, severity)
    link = { label: text('openrouter.link'), url: "#{routes.super_admin_app_config_path(config: 'captain')}#openrouter-diagnostics", note: nil }
    alert("openrouter.#{status}", severity: severity, items: [link], count: 1)
  end

  def credits_low?(credits)
    return false unless credits[:status] == 'available'

    total = credits[:total_credits].to_f
    remaining = credits[:remaining_credits]
    total.positive? && !remaining.nil? && remaining.to_f.positive? && remaining.to_f <= total * LOW_CREDITS_SHARE
  end
end
