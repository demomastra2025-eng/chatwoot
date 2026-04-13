class CreateChannelVkCommunity < ActiveRecord::Migration[7.0]
  def change
    create_table :channel_vk_community do |t|
      t.integer :account_id, null: false
      t.bigint :group_id, null: false
      t.string :access_token
      t.string :secret
      t.string :confirmation_token
      t.string :api_version, null: false, default: '5.199'
      t.string :callback_id, null: false

      t.timestamps
    end

    add_index :channel_vk_community, :group_id, unique: true
    add_index :channel_vk_community, :callback_id, unique: true
  end
end
