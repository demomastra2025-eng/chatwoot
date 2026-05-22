# frozen_string_literal: true

# Example only. Do not copy blindly into production.
# Goal: adapt sinaptia/ruby_llm-monitoring concepts into OneLink-native metrics/alerts.

# Gemfile candidate if we decide to evaluate the engine directly:
# gem 'ruby_llm-monitoring', require: false

if ENV.fetch('ONELINK_RUBY_LLM_MONITORING_EXAMPLE_ENABLED', 'false') == 'true'
  require 'ruby_llm/monitoring'

  RubyLLM::Monitoring.metrics = [
    RubyLLM::Monitoring::Metrics::Throughput,
    RubyLLM::Monitoring::Metrics::Cost,
    RubyLLM::Monitoring::Metrics::ResponseTime,
    RubyLLM::Monitoring::Metrics::ErrorCount
  ]

  RubyLLM::Monitoring.alert_cooldown = 15.minutes

  RubyLLM::Monitoring.channels = {
    # Prefer OneLink notification routing in real implementation.
    slack: { webhook_url: ENV.fetch('LLM_MONITORING_SLACK_WEBHOOK_URL', nil) }
  }.compact

  RubyLLM::Monitoring.alert_rules += [
    {
      time_range: -> { 1.hour.ago.. },
      rule: ->(events) { events.where.not(exception_class: nil).count > 10 },
      channels: [:slack],
      message: { text: 'RubyLLM errors exceeded threshold in the last hour' }
    },
    {
      time_range: -> { Time.current.beginning_of_day.. },
      rule: ->(events) { events.sum(:cost).to_f >= ENV.fetch('LLM_DAILY_COST_ALERT_USD', '100').to_f },
      channels: [:slack],
      message: { text: 'RubyLLM daily cost exceeded threshold' }
    }
  ]
end

# If mounting the engine for a local experiment, protect it:
#
# authenticate :user, ->(user) { user.administrator? } do
#   mount RubyLLM::Monitoring::Engine, at: '/internal/ruby_llm_monitoring'
# end
#
# OneLink production preference:
# - do not expose the generic engine as product UI;
# - persist summarized events through Llm::EventBus;
# - render metrics in OneLink admin/Captain observability screens;
# - add retention cleanup for old events;
# - never store raw prompts/outputs by default.
