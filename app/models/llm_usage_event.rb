# frozen_string_literal: true

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
