# frozen_string_literal: true

class Internal::RefreshOpenRouterKeyHealthJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform
    metadata = Llm::OpenRouterKeyHealth.refresh!
    Rails.logger.info("[Internal::RefreshOpenRouterKeyHealthJob] Refreshed OpenRouter key health: #{metadata.except(:key)}")
  rescue StandardError => e
    error = Llm::ObservabilityPayload.sanitize_error_message(e)
    Rails.logger.warn("[Internal::RefreshOpenRouterKeyHealthJob] OpenRouter key health refresh failed: #{e.class}: #{error}")
  end
end
