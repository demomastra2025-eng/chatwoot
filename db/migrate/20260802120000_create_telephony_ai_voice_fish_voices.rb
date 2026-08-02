class CreateTelephonyAiVoiceFishVoices < ActiveRecord::Migration[7.1]
  def change
    create_table :telephony_ai_voice_fish_voices do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :created_by, null: true, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :provider_model_id, null: false
      t.string :title, null: false
      t.string :state, null: false, default: 'created'
      t.string :visibility, null: false, default: 'private'
      t.timestamps
    end

    add_index :telephony_ai_voice_fish_voices, :provider_model_id,
              unique: true, name: 'index_fish_voices_on_provider_model_id'
    add_index :telephony_ai_voice_fish_voices, [:account_id, :created_at],
              name: 'index_fish_voices_on_account_and_created_at'
  end
end
