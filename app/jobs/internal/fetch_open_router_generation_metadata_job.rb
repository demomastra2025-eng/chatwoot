# frozen_string_literal: true

class Internal::FetchOpenRouterGenerationMetadataJob < ApplicationJob
  queue_as :low

  def perform(llm_event_id, generation_id = nil)
    event = LlmEvent.find_by(id: llm_event_id)
    return if event.blank?

    resolved_generation_id = generation_id.presence || event.payload.to_h['openrouter_generation_id'].presence
    return if resolved_generation_id.blank?

    metadata = fetch_metadata(event, resolved_generation_id)
    event.update!(event_update_attributes(event, metadata))
  rescue StandardError => e
    record_error(event, resolved_generation_id, e) if event.present? && resolved_generation_id.present?
    nil
  end

  private

  def fetch_metadata(event, generation_id)
    account = event.account
    Llm::OpenRouterGenerationClient.fetch(
      generation_id,
      api_key: Llm::Config.api_key('openrouter', account: account),
      api_base: Llm::Config.api_base('openrouter', account: account)
    )
  end

  def event_update_attributes(event, metadata)
    attrs = {
      payload: enriched_payload(event.payload, metadata),
      model: metadata.model.presence || event.model,
      prompt_tokens: metadata.prompt_tokens || event.prompt_tokens,
      completion_tokens: metadata.completion_tokens || event.completion_tokens,
      thinking_tokens: metadata.reasoning_tokens || event.thinking_tokens,
      duration_ms: metadata.latency_ms || event.duration_ms,
      estimated_cost: metadata.cost.presence || event.estimated_cost
    }
    attrs[:total_tokens] = total_tokens(attrs, event)
    attrs.compact
  end

  def enriched_payload(payload, metadata)
    payload.to_h.merge(
      'openrouter_generation_id' => metadata.generation_id,
      'endpoint_provider' => metadata.provider_name,
      'openrouter_generation' => metadata_payload(metadata)
    ).compact
  end

  def metadata_payload(metadata)
    {
      'id' => metadata.generation_id,
      'provider_name' => metadata.provider_name,
      'model' => metadata.model,
      'cost' => metadata.cost,
      'latency_ms' => metadata.latency_ms,
      'prompt_tokens' => metadata.prompt_tokens,
      'completion_tokens' => metadata.completion_tokens,
      'reasoning_tokens' => metadata.reasoning_tokens,
      'cached_tokens' => metadata.cached_tokens
    }.compact
  end

  def record_error(event, generation_id, error)
    payload = event.payload.to_h.merge(
      'openrouter_generation_id' => generation_id,
      'openrouter_generation_error' => {
        'generation_id' => generation_id,
        'error_class' => error.class.name,
        'message' => error.message
      }
    )
    event.update!(payload: payload)
  rescue StandardError => e
    Rails.logger.warn(
      "[Internal::FetchOpenRouterGenerationMetadataJob] Failed to record metadata error for LlmEvent #{event&.id}: " \
      "#{e.class}: #{e.message}"
    )
    nil
  end

  def total_tokens(attrs, event)
    values = [
      attrs[:prompt_tokens],
      attrs[:completion_tokens],
      attrs[:thinking_tokens]
    ].compact
    return event.total_tokens if values.empty?

    values.sum
  end
end
