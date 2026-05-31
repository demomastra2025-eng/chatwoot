# frozen_string_literal: true

# == Schema Information
#
# Table name: llm_model_catalog_entries
#
#  id                   :bigint           not null, primary key
#  canonical_slug       :string
#  capabilities         :jsonb            not null
#  checksum             :string
#  context_length       :integer
#  description          :text
#  disabled_at          :datetime
#  display_name         :string           not null
#  fetched_at           :datetime         not null
#  input_modalities     :jsonb            not null
#  knowledge_cutoff     :string
#  max_output_tokens    :integer
#  model_type           :string           not null
#  output_modalities    :jsonb            not null
#  pricing              :jsonb            not null
#  provider_platform    :string           not null
#  raw_payload          :jsonb            not null
#  source               :string           default("openrouter_api"), not null
#  stale_at             :datetime
#  supported_parameters :jsonb            not null
#  top_provider         :jsonb            not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  model_id             :string           not null
#
# Indexes
#
#  idx_llm_model_catalog_provider_disabled  (provider_platform,disabled_at)
#  idx_llm_model_catalog_provider_model     (provider_platform,model_id) UNIQUE
#  idx_llm_model_catalog_provider_stale     (provider_platform,stale_at)
#  idx_llm_model_catalog_provider_type      (provider_platform,model_type)
#
class Llm::ModelCatalogEntry < ApplicationRecord
  self.table_name = 'llm_model_catalog_entries'

  scope :openrouter, -> { where(provider_platform: Llm::OpenRouterModelCatalog::PROVIDER) }
  scope :active, -> { where(disabled_at: nil) }
  scope :servable, -> { active.where(stale_at: nil) }
  scope :fresh_first, -> { order(Arel.sql('fetched_at DESC NULLS LAST'), :display_name, :model_id) }

  validates :provider_platform, :model_id, :display_name, :model_type, :source, :fetched_at, presence: true
  validates :model_id, uniqueness: { scope: :provider_platform }

  before_validation :assign_canonical_slug

  def to_openrouter_config(embedding_profile: nil)
    {
      'provider' => provider_platform,
      'display_name' => display_name,
      'credit_multiplier' => 1,
      'type' => model_type,
      'capabilities' => string_array(capabilities),
      'input_modalities' => string_array(input_modalities),
      'output_modalities' => string_array(output_modalities),
      'supported_parameters' => string_array(supported_parameters),
      'context_length' => context_length,
      'max_output_tokens' => max_output_tokens,
      'pricing' => hash_value(pricing),
      'top_provider' => hash_value(top_provider),
      'latency_ms' => latency_ms,
      'throughput_tokens_per_second' => throughput_tokens_per_second,
      'knowledge_cutoff' => knowledge_cutoff,
      'description' => description,
      'source' => source
    }.merge(embedding_config(embedding_profile)).compact
  end

  private

  def assign_canonical_slug
    self.canonical_slug = model_id.to_s.strip.downcase if canonical_slug.blank? && model_id.present?
  end

  def embedding_config(embedding_profile)
    return {} unless embedding_profile

    {
      'embedding_dimensions' => embedding_profile.default_dimensions,
      'requested_embedding_dimensions' => Captain::KnowledgeSettings::VECTOR_DIMENSIONS,
      'supported_embedding_dimensions' => embedding_profile.supported_dimensions,
      'supports_embedding_dimension_override' => embedding_profile.supports_dimension_override,
      'supports_embedding_input_type' => embedding_profile.supports_input_type
    }.compact
  end

  def latency_ms
    top_provider_data = hash_value(top_provider)
    raw_payload_data = hash_value(raw_payload)
    latency = top_provider_data['latency_ms'] || top_provider_data['latency'] || raw_payload_data['latency_ms'] || raw_payload_data['latency']

    numeric_value(latency)
  end

  def throughput_tokens_per_second
    top_provider_data = hash_value(top_provider)
    raw_payload_data = hash_value(raw_payload)
    numeric_value(
      top_provider_data['throughput_tokens_per_second'] ||
        top_provider_data['throughput'] ||
        raw_payload_data['throughput_tokens_per_second'] ||
        raw_payload_data['tokens_per_second'] ||
        raw_payload_data['throughput']
    )
  end

  def numeric_value(value)
    return if value.blank?

    Float(value)
  rescue ArgumentError, TypeError
    nil
  end

  def string_array(value)
    Array(value).map(&:to_s)
  end

  def hash_value(value)
    value.is_a?(Hash) ? value.deep_stringify_keys : {}
  end
end
