# frozen_string_literal: true

# == Schema Information
#
# Table name: llm_usage_events
#
#  id                :bigint           not null, primary key
#  actual_model      :string
#  actual_provider   :string
#  cached_tokens     :integer
#  completion_tokens :integer
#  duration_ms       :integer
#  error_code        :string
#  estimated_cost    :decimal(14, 8)
#  event_name        :string           not null
#  feature           :string
#  metadata          :jsonb            not null
#  occurred_at       :datetime         not null
#  prompt_tokens     :integer
#  provider          :string
#  reasoning_tokens  :integer
#  requested_model   :string
#  routing_profile   :string
#  status            :string
#  total_tokens      :integer
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  account_id        :integer
#  generation_id     :string
#  llm_event_id      :bigint           not null
#  request_id        :string
#  session_id        :string
#  trace_id          :string
#
# Indexes
#
#  idx_llm_usage_events_account_feature_occurred  (account_id,feature,occurred_at)
#  idx_llm_usage_events_account_generation        (account_id,generation_id) WHERE (generation_id IS NOT NULL)
#  idx_llm_usage_events_account_occurred          (account_id,occurred_at)
#  idx_llm_usage_events_provider_occurred         (provider,occurred_at)
#  index_llm_usage_events_on_llm_event_id         (llm_event_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (llm_event_id => llm_events.id) ON DELETE => cascade
#
class LlmUsageEvent < ApplicationRecord
  belongs_to :account, optional: true
  belongs_to :llm_event

  validates :event_name, :occurred_at, presence: true

  scope :for_account, ->(account_id) { where(account_id: account_id) if account_id.present? }
  scope :for_feature, lambda { |feature|
    feature_keys = Llm::FeatureProfile.equivalent_feature_keys(feature)
    where(feature: feature_keys) if feature_keys.present?
  }
  scope :for_provider, ->(provider) { where(provider: provider) if provider.present? }
  scope :for_date_range, ->(range) { where(occurred_at: range) if range.present? }
end
