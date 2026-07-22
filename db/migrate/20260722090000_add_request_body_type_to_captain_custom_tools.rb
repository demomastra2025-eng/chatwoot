class AddRequestBodyTypeToCaptainCustomTools < ActiveRecord::Migration[7.1]
  def change
    add_column :captain_custom_tools, :request_body_type, :string, default: 'json', null: false
  end
end
