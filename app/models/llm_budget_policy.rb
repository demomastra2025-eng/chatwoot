# frozen_string_literal: true

class LlmBudgetPolicy < ApplicationRecord
  SCOPE_TYPES = %w[account global].freeze

  belongs_to :account, optional: true

  validates :scope_type, presence: true, inclusion: { in: SCOPE_TYPES }
  validates :account, presence: true, if: :account_scope?
  validates :account_id, absence: true, if: :global_scope?
  validates :warning_threshold, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }, allow_nil: true
  validates :daily_budget, :monthly_budget, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

  scope :active, -> { where(active: true) }
  scope :with_budget_limits, -> { where.not(daily_budget: nil).or(where.not(monthly_budget: nil)) }
  scope :matching_account, lambda { |account|
    account_id = account.respond_to?(:id) ? account.id : account
    return where(account_id: nil) if account_id.blank?

    where(account_id: account_id).or(where(account_id: nil))
  }
  scope :matching_feature, lambda { |feature|
    feature_keys = Llm::FeatureProfile.equivalent_feature_keys(feature)
    return where(feature: nil) if feature_keys.blank?

    where(feature: feature_keys).or(where(feature: nil))
  }

  class << self
    def applicable_to(account:, feature: nil)
      active
        .matching_account(account)
        .matching_feature(feature)
        .order(
          Arel.sql('CASE WHEN account_id IS NULL THEN 1 ELSE 0 END ASC'),
          Arel.sql('CASE WHEN feature IS NULL THEN 1 ELSE 0 END ASC'),
          :id
        )
    end
  end

  private

  def account_scope?
    scope_type == 'account'
  end

  def global_scope?
    scope_type == 'global'
  end
end
