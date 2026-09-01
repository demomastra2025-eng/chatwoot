class CreateBillingOrganizations < ActiveRecord::Migration[7.1]
  def change
    create_table :billing_organizations do |t|
      t.string :name, null: false
      t.integer :status, null: false, default: 0

      t.timestamps
    end

    add_reference :accounts, :billing_organization, foreign_key: true, index: true
  end
end
