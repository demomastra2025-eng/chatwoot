# frozen_string_literal: true

class Telephony::VirtualPbx::LegacyResourceResolver
  def initialize(account:)
    @account = account
  end

  def resolve(config)
    ownership = (config[:ownership] || {}).with_indifferent_access
    return { status: 'managed', read_only: false, conflicts: [] } if ownership[:managed_by] == 'onelink' && !ownership[:read_only]

    {
      status: 'requires_manual_reconcile',
      read_only: true,
      conflicts: [
        {
          code: 'legacy_resource_read_only',
          message: 'Existing Fonoster resource has no OneLink ownership metadata and requires explicit migration approval'
        }
      ]
    }
  end

  private

  attr_reader :account
end
