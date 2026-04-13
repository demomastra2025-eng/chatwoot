# frozen_string_literal: true

class Internal::EnforceLlmEventRetentionJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform
    summary = Llm::Monitoring::RetentionEnforcer.new.call
    Rails.logger.info("[Internal::EnforceLlmEventRetentionJob] #{summary}")
  end
end
