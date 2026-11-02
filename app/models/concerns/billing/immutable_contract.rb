# frozen_string_literal: true

# Opt these models into Rails' raising readonly behaviour without changing the global compatibility setting.
module Billing::ImmutableContract
  extend ActiveSupport::Concern

  included do
    include ActiveRecord::ReadonlyAttributes::HasReadonlyAttributes
    before_validation :reject_in_place_contract_changes
  end

  private

  def reject_in_place_contract_changes
    return if new_record?

    changed = self.class.readonly_attributes.find { |name| will_save_change_to_attribute?(name) }
    raise ActiveRecord::ReadonlyAttributeError, changed if changed
  end
end
