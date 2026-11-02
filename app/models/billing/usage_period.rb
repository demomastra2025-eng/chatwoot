# frozen_string_literal: true

# Explicitly proved calendar terms. The ledger never bootstraps a period from today's plan.
class Billing::UsagePeriod < ApplicationRecord
  belongs_to :billing_account, class_name: 'BillingAccount'
  belongs_to :billing_subscription, class_name: 'BillingSubscription'
  has_many :usage_revisions, foreign_key: :billing_usage_period_id, dependent: :restrict_with_error, inverse_of: :usage_period
  include Billing::ImmutableContract
  attr_readonly :billing_account_id, :billing_subscription_id, :month, :plan_snapshot, :price_snapshot, :anchor_starts_at, :anchor_ends_at

  validates :month, presence: true
  validates :dialogs_count, :call_seconds, :revision, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :calendar_month
  validate :complete_snapshot
  validate :proven_subscription, on: :create
  before_validation :capture_anchor, on: :create

  def starts_at
    month&.in_time_zone(Billing::ALMATY_TIMEZONE)&.beginning_of_month
  end

  def ends_at
    starts_at&.next_month
  end

  def call_minutes
    (call_seconds + 59) / 60
  end

  private

  def capture_anchor
    self.anchor_starts_at ||= billing_subscription&.current_period_starts_at
    self.anchor_ends_at ||= billing_subscription&.current_period_ends_at
  end

  def calendar_month
    errors.add(:month, 'must be a calendar month start') if month && month.day != 1
  end

  def complete_snapshot
    errors.add(:base, 'missing immutable terms') unless Billing::PlanSnapshot.valid_historical?(plan_snapshot, price_snapshot)
  end

  def proven_subscription
    subscription = billing_subscription
    valid = ready_inputs?(subscription) && matching_terms?(subscription) && proven_anchor?(subscription)
    errors.add(:base, 'unproved historical terms') unless valid
  end

  def ready_inputs?(subscription)
    subscription&.persisted? && subscription.ready? && billing_account&.ready? && starts_at
  end

  def matching_terms?(subscription)
    subscription.billing_account_id == billing_account_id && subscription.plan_snapshot == plan_snapshot &&
      subscription.price_snapshot == price_snapshot
  end

  def proven_anchor?(subscription)
    matches = [anchor_starts_at, anchor_ends_at] == [subscription.current_period_starts_at, subscription.current_period_ends_at]
    matches && anchor_starts_at && anchor_ends_at && subscription.created_at <= starts_at &&
      anchor_starts_at <= starts_at && anchor_ends_at > starts_at
  end
end
