# frozen_string_literal: true

class CascadeAssignmentTrackingRecordsOnContactDelete < ActiveRecord::Migration[7.1]
  OWNERSHIP_FOREIGN_KEY = 'fk_rails_assignment_client_ownerships_contact'
  QUOTA_USAGE_FOREIGN_KEY = 'fk_rails_assignment_quota_usages_contact'

  def up
    replace_contact_foreign_key(:assignment_client_ownerships, OWNERSHIP_FOREIGN_KEY, :cascade)
    replace_contact_foreign_key(:assignment_quota_usages, QUOTA_USAGE_FOREIGN_KEY, :cascade)
  end

  def down
    replace_contact_foreign_key(:assignment_client_ownerships, OWNERSHIP_FOREIGN_KEY)
    replace_contact_foreign_key(:assignment_quota_usages, QUOTA_USAGE_FOREIGN_KEY)
  end

  private

  def replace_contact_foreign_key(table, name, on_delete = nil)
    connection.foreign_keys(table).each do |foreign_key|
      next unless foreign_key.to_table == 'contacts' && foreign_key.column == 'contact_id'

      remove_foreign_key table, name: foreign_key.name
    end
    add_foreign_key table, :contacts, name: name, on_delete: on_delete
  end
end
