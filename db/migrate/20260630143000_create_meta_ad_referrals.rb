class CreateMetaAdReferrals < ActiveRecord::Migration[7.1]
  def change
    create_table :meta_ad_referrals do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :inbox, null: false, foreign_key: { on_delete: :cascade }
      t.references :contact, foreign_key: { on_delete: :nullify }
      t.references :conversation, foreign_key: { on_delete: :nullify }
      t.references :communication_thread, foreign_key: { on_delete: :nullify }
      t.references :message, foreign_key: { on_delete: :nullify }
      t.string :provider, null: false
      t.string :provider_message_id, null: false
      t.string :attribution_type
      t.string :source
      t.string :source_type
      t.string :source_id
      t.text :source_url
      t.string :ad_id
      t.string :ctwa_clid
      t.string :ref
      t.string :referral_type
      t.string :headline
      t.text :body
      t.string :media_type
      t.text :image_url
      t.text :video_url
      t.text :thumbnail_url
      t.string :post_id
      t.string :product_id
      t.string :flow_id
      t.jsonb :raw_referral, default: {}, null: false
      t.datetime :received_at, null: false

      t.timestamps
    end

    add_index :meta_ad_referrals, [:provider, :inbox_id, :provider_message_id], unique: true,
                                                                                name: 'idx_meta_ad_referrals_provider_message'
    add_index :meta_ad_referrals, [:account_id, :ctwa_clid], where: 'ctwa_clid IS NOT NULL',
                                                             name: 'idx_meta_ad_referrals_account_ctwa'
    add_index :meta_ad_referrals, [:account_id, :ad_id], where: 'ad_id IS NOT NULL',
                                                         name: 'idx_meta_ad_referrals_account_ad'
    add_index :meta_ad_referrals, [:account_id, :source_id], where: 'source_id IS NOT NULL',
                                                             name: 'idx_meta_ad_referrals_account_source'
    add_index :meta_ad_referrals, [:account_id, :communication_thread_id],
              name: 'idx_meta_ad_referrals_account_thread'
    add_index :meta_ad_referrals, [:account_id, :conversation_id], name: 'idx_meta_ad_referrals_account_conversation'
  end
end
