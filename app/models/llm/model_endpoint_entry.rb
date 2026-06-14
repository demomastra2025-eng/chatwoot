# frozen_string_literal: true

# == Schema Information
#
# Table name: llm_model_endpoint_entries
#
#  id                           :bigint           not null, primary key
#  capabilities                 :jsonb            not null
#  checksum                     :string
#  context_length               :integer
#  data_collection              :string
#  endpoint_provider_key        :string
#  endpoint_provider_name       :string
#  endpoint_slug                :string           not null
#  fetched_at                   :datetime         not null
#  latency_ms                   :integer
#  max_completion_tokens        :integer
#  max_prompt_tokens            :integer
#  pricing                      :jsonb            not null
#  provider_platform            :string           not null
#  quantization                 :string
#  raw_payload                  :jsonb            not null
#  stale_at                     :datetime
#  supported_parameters         :jsonb            not null
#  throughput_tokens_per_second :decimal(12, 4)
#  uptime_last_30m              :decimal(5, 2)
#  zdr                          :boolean
#  created_at                   :datetime         not null
#  updated_at                   :datetime         not null
#  model_id                     :string           not null
#
# Indexes
#
#  idx_llm_endpoint_provider_key             (provider_platform,endpoint_provider_key)
#  idx_llm_endpoint_provider_model           (provider_platform,model_id)
#  idx_llm_endpoint_provider_model_key_slug  (provider_platform,model_id,endpoint_provider_key,endpoint_slug) UNIQUE
#  idx_llm_endpoint_provider_stale           (provider_platform,stale_at)
#
class Llm::ModelEndpointEntry < ApplicationRecord
  self.table_name = 'llm_model_endpoint_entries'

  scope :openrouter, -> { where(provider_platform: Llm::OpenRouterModelCatalog::PROVIDER) }
  scope :servable, -> { where(stale_at: nil) }
  scope :fresh_first, -> { order(Arel.sql('fetched_at DESC NULLS LAST'), :model_id, :endpoint_provider_name, :endpoint_slug) }

  validates :provider_platform, :model_id, :endpoint_slug, :fetched_at, presence: true
  validates :endpoint_slug, uniqueness: { scope: [:provider_platform, :model_id, :endpoint_provider_key] }

  before_validation :assign_endpoint_provider_key

  def to_openrouter_endpoint
    {
      'name' => raw_payload_name,
      'provider_name' => endpoint_provider_name,
      'tag' => endpoint_slug,
      'status' => raw_payload_status,
      'quantization' => quantization,
      'context_length' => context_length,
      'max_prompt_tokens' => max_prompt_tokens,
      'max_completion_tokens' => max_completion_tokens,
      'max_output_tokens' => max_completion_tokens,
      'supported_parameters' => string_array(supported_parameters),
      'capabilities' => derived_capabilities,
      'pricing' => hash_value(pricing),
      'latency_ms' => latency_ms&.to_f,
      'throughput_tokens_per_second' => throughput_tokens_per_second&.to_f,
      'uptime_last_30m' => uptime_last_30m&.to_f,
      'provider_key' => endpoint_provider_key,
      'data_collection' => data_collection,
      'zdr' => zdr
    }.compact
  end

  private

  def assign_endpoint_provider_key
    self.endpoint_provider_key = endpoint_provider_name.to_s.parameterize if endpoint_provider_key.blank? && endpoint_provider_name.present?
  end

  def raw_payload_name
    hash_value(raw_payload)['name'].presence
  end

  def raw_payload_status
    hash_value(raw_payload)['status'].presence
  end

  def string_array(value)
    Array(value).map(&:to_s)
  end

  def derived_capabilities
    Llm::OpenRouterParameterCapabilities.derive(
      capabilities: capabilities,
      supported_parameters: supported_parameters
    )
  end

  def hash_value(value)
    value.is_a?(Hash) ? value.deep_stringify_keys : {}
  end
end
