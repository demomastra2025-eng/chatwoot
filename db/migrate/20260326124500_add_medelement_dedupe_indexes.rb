class AddMedelementDedupeIndexes < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  CONTACTS_INDEX_NAME = 'idx_contacts_account_medelement_patient_code'.freeze
  RESOURCES_INDEX_NAME = 'idx_scheduling_resources_account_medelement_specialist_code'.freeze

  def up
    add_index :contacts,
              "account_id, (custom_attributes ->> 'medelement_patient_code')",
              unique: true,
              where: "(custom_attributes ->> 'medelement_patient_code') IS NOT NULL",
              algorithm: :concurrently,
              name: CONTACTS_INDEX_NAME

    add_index :scheduling_resources,
              "account_id, (custom_attributes ->> 'medelement_specialist_code')",
              unique: true,
              where: "(custom_attributes ->> 'medelement_specialist_code') IS NOT NULL",
              algorithm: :concurrently,
              name: RESOURCES_INDEX_NAME
  end

  def down
    remove_index :contacts, name: CONTACTS_INDEX_NAME, algorithm: :concurrently, if_exists: true
    remove_index :scheduling_resources, name: RESOURCES_INDEX_NAME, algorithm: :concurrently, if_exists: true
  end
end
