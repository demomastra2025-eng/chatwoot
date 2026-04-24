class AddAllowFileArtifactsToCaptainCustomTools < ActiveRecord::Migration[7.0]
  def change
    add_column :captain_custom_tools, :allow_file_artifacts, :boolean, default: true, null: false
  end
end
