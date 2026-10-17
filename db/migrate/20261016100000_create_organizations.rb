# The organization is the paying parent of accounts (requisites, BIN, contract); its accounts are its branches or
# departments. Additive only: an account without an organization works exactly as before, and nothing is backfilled.
class CreateOrganizations < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  def change
    create_table :organizations, if_not_exists: true do |t|
      t.string :name, null: false
      t.string :legal_name
      # Kazakhstan BIN: 12 digits. Blank is stored as NULL, so the unique index only holds BINs that are filled in.
      t.string :bin
      t.string :contract_number
      t.date :contract_date
      t.string :billing_email
      t.string :phone
      t.text :address
      t.text :notes
      t.jsonb :custom_attributes, null: false, default: {}
      t.timestamps
    end

    add_index :organizations, 'lower(name)', name: 'index_organizations_on_lower_name', if_not_exists: true
    add_index :organizations, :bin, unique: true, if_not_exists: true

    add_reference :accounts, :organization, null: true, index: { algorithm: :concurrently }, foreign_key: false, if_not_exists: true
    add_foreign_key :accounts, :organizations, validate: false, if_not_exists: true
  end
end
