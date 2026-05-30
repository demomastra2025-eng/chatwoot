# frozen_string_literal: true

class Internal::RefreshOpenRouterModelCatalogJob < ApplicationJob
  queue_as :scheduled_jobs
  REFRESH_FAILED_MESSAGE = 'OpenRouter model catalog refresh failed'

  def perform
    unless Llm::Config.installation_provider_available?(Llm::OpenRouterModelCatalog::PROVIDER)
      Rails.logger.info('[Internal::RefreshOpenRouterModelCatalogJob] Skipping OpenRouter catalog refresh: global key is not configured')
      return
    end

    metadata = Llm::ModelRegistryService.refresh_openrouter!
    summary = metadata.slice(:total_models, :source, :last_refreshed_at)
    Rails.logger.info("[Internal::RefreshOpenRouterModelCatalogJob] Refreshed OpenRouter catalog: #{summary}")
  rescue StandardError => e
    error = Llm::OpenRouterModelCatalog.sanitize_error_message(e)
    Rails.logger.warn("[Internal::RefreshOpenRouterModelCatalogJob] OpenRouter catalog refresh failed: #{e.class}: #{error}")
  end
end
