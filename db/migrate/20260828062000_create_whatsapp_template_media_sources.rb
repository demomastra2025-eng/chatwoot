class CreateWhatsappTemplateMediaSources < ActiveRecord::Migration[7.1]
  def change
    create_table :whatsapp_template_media_sources do |t|
      t.references :whatsapp_channel,
                   null: false,
                   foreign_key: { to_table: :channel_whatsapp, on_delete: :cascade }
      t.string :template_name, null: false
      t.string :language, null: false
      t.integer :card_index, null: false
      t.string :media_type, null: false
      t.text :source_url
      t.string :meta_media_id
      t.datetime :meta_media_uploaded_at
      t.timestamps
    end

    add_index :whatsapp_template_media_sources,
              [:whatsapp_channel_id, :template_name, :language, :card_index],
              unique: true,
              name: 'idx_wa_template_media_source_identity'
  end
end
