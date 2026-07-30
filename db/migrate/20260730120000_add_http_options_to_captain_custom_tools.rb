class AddHttpOptionsToCaptainCustomTools < ActiveRecord::Migration[7.1]
  def change
    add_column :captain_custom_tools, :http_options, :jsonb, default: {}, null: false
  end
end
