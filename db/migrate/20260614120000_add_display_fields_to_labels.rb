class AddDisplayFieldsToLabels < ActiveRecord::Migration[7.1]
  def up
    add_column :labels, :display_title, :string unless column_exists?(:labels, :display_title)
    add_column :labels, :marker_type, :string, default: 'color', null: false unless column_exists?(:labels, :marker_type)
    add_column :labels, :emoji, :string unless column_exists?(:labels, :emoji)

    execute <<~SQL.squish
      UPDATE labels
      SET display_title = title
      WHERE display_title IS NULL OR display_title = ''
    SQL
  end

  def down
    remove_column :labels, :emoji if column_exists?(:labels, :emoji)
    remove_column :labels, :marker_type if column_exists?(:labels, :marker_type)
    remove_column :labels, :display_title if column_exists?(:labels, :display_title)
  end
end
