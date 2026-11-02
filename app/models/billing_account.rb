# frozen_string_literal: true

# Source-only foundation. No Account callback, bootstrap or entitlement reader uses this yet.
class BillingAccount < ApplicationRecord
  STATES = %w[ready legacy_pending].freeze
  STATUSES = %w[active past_due suspended closed].freeze

  belongs_to :organization, optional: true
  belongs_to :standalone_account, class_name: 'Account', optional: true
  has_many :billing_subscriptions, dependent: :restrict_with_error
  has_many :billing_account_workspaces, dependent: :restrict_with_error

  include Billing::ImmutableContract
  attr_readonly :organization_id, :standalone_account_id, :foundation_state

  validates :name, presence: true
  validates :foundation_state, inclusion: { in: STATES }
  validates :status, inclusion: { in: STATUSES }
  validates :default_currency, inclusion: { in: ['KZT'] }, if: :ready?
  validate :explicit_owner, if: :ready?
  validate :new_records_are_ready, on: :create

  scope :ready, -> { where(foundation_state: 'ready') }

  def ready?
    foundation_state == 'ready'
  end

  def readonly?
    super || (persisted? && !ready?)
  end

  private

  def explicit_owner
    return if organization.present? ^ standalone_account.present?

    errors.add(:base, 'requires exactly one explicit owner')
  end

  def new_records_are_ready
    errors.add(:foundation_state, 'legacy_pending is reserved for pre-existing records') unless ready?
  end
end
