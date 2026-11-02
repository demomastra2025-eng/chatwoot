# frozen_string_literal: true

class BillingAccountWorkspace < ApplicationRecord
  belongs_to :billing_account
  belongs_to :account
  include Billing::ImmutableContract
  attr_readonly :billing_account_id, :account_id, :starts_at, :foundation_state

  validates :foundation_state, inclusion: { in: BillingAccount::STATES }
  validates :status, inclusion: { in: %w[active detached] }
  validates :starts_at, presence: true, if: :ready?
  validate :complete_interval, if: :ready?
  validate :closed_interval_is_immutable, if: :ready?
  validate :workspace_matches_owner, on: :create, if: :ready?
  validate :new_records_are_ready, on: :create

  scope :ready, -> { where(foundation_state: 'ready') }

  def ready?
    foundation_state == 'ready'
  end

  def readonly?
    super || (persisted? && !ready?)
  end

  private

  def complete_interval
    errors.add(:billing_account, 'must be ready') unless billing_account&.ready?
    errors.add(:detached_at, 'must follow starts_at') if starts_at && detached_at && detached_at <= starts_at
    errors.add(:detached_at, 'does not match status') unless (status == 'active') == detached_at.nil?
  end

  def closed_interval_is_immutable
    return unless persisted? && detached_at_in_database.present? && will_save_change_to_detached_at?

    errors.add(:detached_at, 'a closed historical interval cannot be rewritten')
  end

  # Check the link being created, never reinterpret a saved interval using today's organization.
  def workspace_matches_owner
    return unless billing_account && account

    matches = if billing_account.standalone_account_id
                billing_account.standalone_account_id == account_id
              else
                billing_account.organization_id.present? && billing_account.organization_id == account.organization_id
              end
    errors.add(:account, 'does not belong to the explicit payer') unless matches
  end

  def new_records_are_ready
    errors.add(:foundation_state, 'legacy_pending is reserved for pre-existing records') unless ready?
  end
end
