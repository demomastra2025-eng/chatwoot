# frozen_string_literal: true

class EnforceAssignmentTrackingContactDeleteCascade < ActiveRecord::Migration[7.1]
  FOREIGN_KEYS = {
    assignment_client_ownerships: 'fk_rails_assignment_client_ownerships_contact',
    assignment_quota_usages: 'fk_rails_assignment_quota_usages_contact'
  }.freeze

  def up
    replace_contact_foreign_keys(on_delete: :cascade)
  end

  def down
    replace_contact_foreign_keys(on_delete: nil)
  end

  private

  def replace_contact_foreign_keys(on_delete:)
    FOREIGN_KEYS.each do |table, name|
      remove_foreign_key table, name: name if foreign_key_exists?(table, name: name)
      add_foreign_key table, :contacts, name: name, on_delete: on_delete
    end
  end
end
