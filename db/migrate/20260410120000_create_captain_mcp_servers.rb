class CreateCaptainMcpServers < ActiveRecord::Migration[7.1]
  def change
    create_table :captain_mcp_servers do |t|
      t.references :account, null: false, foreign_key: true
      t.string :name, null: false
      t.string :slug, null: false
      t.text :description
      t.string :transport_type, null: false
      t.jsonb :server_config, null: false, default: {}
      t.jsonb :allowed_scopes, null: false, default: []
      t.integer :request_timeout, null: false, default: 30
      t.boolean :enabled, null: false, default: true

      t.timestamps
    end

    add_index :captain_mcp_servers, [:account_id, :slug], unique: true
    add_index :captain_mcp_servers, [:account_id, :enabled]
  end
end
