# frozen_string_literal: true

class Billing::UsageRevision < ApplicationRecord
  belongs_to :usage_period, foreign_key: :billing_usage_period_id, inverse_of: :usage_revisions
  belongs_to :usage_projection, foreign_key: :billing_usage_projection_id, inverse_of: :usage_revisions

  validates :revision, :projection_version, numericality: { only_integer: true, greater_than: 0 }
  validates :dialogs_delta, :seconds_delta, numericality: { only_integer: true }
  validate :nonzero_change

  def readonly?
    super || persisted?
  end

  private

  def nonzero_change
    errors.add(:base, 'empty revision') if dialogs_delta.to_i.zero? && seconds_delta.to_i.zero?
  end
end
