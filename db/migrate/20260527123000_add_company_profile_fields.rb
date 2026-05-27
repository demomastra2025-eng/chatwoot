class AddCompanyProfileFields < ActiveRecord::Migration[7.1]
  def change
    add_column :companies, :additional_attributes, :jsonb, default: {}, null: false
    add_column :companies, :custom_attributes, :jsonb, default: {}, null: false
    add_column :companies, :last_activity_at, :datetime
  end
end
