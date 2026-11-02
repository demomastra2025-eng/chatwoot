# frozen_string_literal: true

# Financial allocations survive Contact deletion and the mutable AiDialogState's merge/reset.
class Billing::UsageProjection < ApplicationRecord
  SOURCE_KEYS = %w[at bucket period_id quantity subscription_id workspace_id].freeze
  INTEGER_SOURCE_KEYS = %w[period_id quantity subscription_id workspace_id].freeze
  BUCKETS = [Accounts::MonthlyAiUsageService::AI_DIALOGS_MONTHLY_KEY, Accounts::MonthlyAiUsageService::CALL_SECONDS_MONTHLY_KEY].freeze

  belongs_to :account
  belongs_to :retired_into, class_name: name, optional: true
  has_many :usage_revisions, foreign_key: :billing_usage_projection_id, dependent: :restrict_with_error, inverse_of: :usage_projection
  include Billing::ImmutableContract
  attr_readonly :account_id, :kind, :subject_id

  validates :kind, inclusion: { in: %w[contact call] }
  validates :subject_id, :version, numericality: { only_integer: true, greater_than: 0 }
  validates :fingerprint, format: { with: /\A[0-9a-f]{64}\z/ }
  validate :numeric_payload

  def retired?
    retired_at.present?
  end

  private

  def numeric_payload
    valid = sources_valid? && allocations_valid? && windows_valid?
    errors.add(:base, 'invalid numeric ledger payload') unless valid
    errors.add(:base, 'incomplete retirement') unless retired_at.nil? == retired_into_id.nil?
  end

  def positive?(value)
    value.is_a?(Integer) && value.positive?
  end

  def numeric_keys?(value)
    value.is_a?(Hash) && value.keys.all? { |key| key.is_a?(String) && key.match?(/\A[1-9]\d*\z/) }
  end

  def sources_valid?
    numeric_keys?(sources) && sources.values.all? { |source| source_valid?(source) }
  end

  def source_valid?(source)
    valid = source.is_a?(Hash) && source.keys.all?(String) && source.keys.sort == SOURCE_KEYS
    valid && BUCKETS.include?(source['bucket']) && INTEGER_SOURCE_KEYS.all? { |key| positive?(source[key]) } &&
      source_time?(source['at'])
  end

  def source_time?(value)
    value.is_a?(String) && value.match?(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}Z\z/)
  end

  def allocations_valid?
    numeric_keys?(allocations) && allocations.values.all? do |units|
      units.is_a?(Hash) && units.keys.sort == %w[dialogs seconds] && units.values.all? { |value| value.is_a?(Integer) && value >= 0 }
    end
  end

  def windows_valid?
    window_sources.is_a?(Array) && window_sources.all? { |pair| pair.is_a?(Array) && pair.length == 2 && pair.all? { |id| positive?(id) } }
  end
end
