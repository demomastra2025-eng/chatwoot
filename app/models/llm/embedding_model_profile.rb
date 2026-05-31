# frozen_string_literal: true

# == Schema Information
#
# Table name: llm_embedding_model_profiles
#
#  id                          :bigint           not null, primary key
#  default_dimensions          :integer
#  max_dimensions              :integer
#  min_dimensions              :integer
#  probe_error                 :text
#  probe_status                :string
#  probed_at                   :datetime
#  provider_platform           :string           not null
#  supported_dimensions        :jsonb            not null
#  supports_dimension_override :boolean          default(FALSE), not null
#  supports_image_input        :boolean          default(FALSE), not null
#  supports_input_type         :boolean          default(FALSE), not null
#  supports_text_input         :boolean          default(FALSE), not null
#  created_at                  :datetime         not null
#  updated_at                  :datetime         not null
#  model_id                    :string           not null
#
# Indexes
#
#  idx_llm_embedding_profiles_provider_model   (provider_platform,model_id) UNIQUE
#  idx_llm_embedding_profiles_provider_status  (provider_platform,probe_status)
#
class Llm::EmbeddingModelProfile < ApplicationRecord
  self.table_name = 'llm_embedding_model_profiles'

  scope :openrouter, -> { where(provider_platform: Llm::OpenRouterModelCatalog::PROVIDER) }

  validates :provider_platform, :model_id, presence: true
  validates :model_id, uniqueness: { scope: :provider_platform }

  def compatible_with_default_vector_dimensions?
    supported_dimensions.include?(Captain::KnowledgeSettings::VECTOR_DIMENSIONS) ||
      default_dimensions == Captain::KnowledgeSettings::VECTOR_DIMENSIONS
  end
end
