# frozen_string_literal: true

class Internal::RefreshOpenRouterModelCatalogJob < ApplicationJob
  queue_as :scheduled_jobs
  REFRESH_FAILED_MESSAGE = 'OpenRouter model catalog refresh failed'
  ENDPOINT_CONTINUATION_DELAY = 1.minute

  def perform(endpoint_only: false)
    unless openrouter_key_configured?
      Rails.logger.info('[Internal::RefreshOpenRouterModelCatalogJob] Skipping OpenRouter catalog refresh: global key is not configured')
      return
    end
    return unless openrouter_key_healthy_for_refresh?

    metadata = endpoint_only ? refresh_endpoint_batch : Llm::ModelRegistryService.refresh_openrouter!
    model_diff = endpoint_only ? {} : metadata.fetch(:last_refresh_diff, {}).to_h
    endpoint_metadata = endpoint_only ? metadata : metadata.fetch(:endpoints, {})
    endpoint_diff = endpoint_metadata.to_h.fetch(:last_refresh_diff, {}).to_h
    summary = metadata.slice(:total_models, :source, :refresh_status, :last_refreshed_at).merge(
      model_diff: diff_counts(model_diff),
      endpoint_diff: diff_counts(endpoint_diff),
      endpoint_pending_model_count: endpoint_metadata.to_h[:pending_model_count].to_i
    )
    Rails.logger.info("[Internal::RefreshOpenRouterModelCatalogJob] Refreshed OpenRouter catalog: #{summary}")
    enqueue_endpoint_continuation(endpoint_metadata)
  rescue StandardError => e
    error = Llm::OpenRouterModelCatalog.sanitize_error_message(e)
    Rails.logger.warn("[Internal::RefreshOpenRouterModelCatalogJob] OpenRouter catalog refresh failed: #{e.class}: #{error}")
  end

  private

  def openrouter_key_configured?
    Llm::Config.installation_provider_available?(Llm::OpenRouterModelCatalog::PROVIDER)
  end

  def openrouter_key_healthy_for_refresh?
    metadata = Llm::OpenRouterKeyHealth.refresh!
    return true if Llm::OpenRouterKeyHealth.catalog_refresh_allowed?(metadata)

    reason = Llm::OpenRouterKeyHealth.catalog_refresh_block_reason(metadata)
    Rails.logger.warn("[Internal::RefreshOpenRouterModelCatalogJob] Skipping OpenRouter catalog refresh: #{reason}")
    false
  end

  def refresh_endpoint_batch
    Llm::ModelRegistryService.refresh_openrouter_endpoints!
  end

  def enqueue_endpoint_continuation(endpoint_metadata)
    return unless endpoint_metadata.to_h[:pending_model_count].to_i.positive?

    self.class.set(wait: ENDPOINT_CONTINUATION_DELAY).perform_later(endpoint_only: true)
  end

  def diff_counts(diff)
    diff.to_h.transform_values { |value| Array(value).count }
  end
end
