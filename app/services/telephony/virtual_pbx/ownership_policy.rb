# frozen_string_literal: true

class Telephony::VirtualPbx::OwnershipPolicy
  MANAGED_BY_ONELINK = 'onelink'
  MANAGED_STATUSES = %w[local managed].freeze

  def initialize(account:)
    @account = account
  end

  def check!(operation:, desired_state:)
    ownership = (desired_state[:ownership] || {}).with_indifferent_access
    managed_by = ownership[:managed_by].presence
    status = ownership[:ownership_status].presence
    read_only = ActiveModel::Type::Boolean.new.cast(ownership[:read_only])
    managed = managed_by == MANAGED_BY_ONELINK && (status.blank? || status.in?(MANAGED_STATUSES)) && !read_only

    if managed
      { allowed: true, risk: 'safe', operation: operation }
    else
      {
        allowed: false,
        risk: 'blocked',
        operation: operation,
        conflict: 'legacy/unowned resource requires explicit migration before remote provisioning'
      }
    end
  end

  def delete_strategy(provider_connection:)
    shared = provider_connection.present? && provider_connection.number_bindings.count > 1
    {
      delete_provider_connection: provider_connection.present? && !shared,
      unlink_provider_connection: shared,
      shared: shared
    }
  end

  private

  attr_reader :account
end
