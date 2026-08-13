# The two tables form one durable campaign audience snapshot and ship together.
# rubocop:disable Metrics/AbcSize, Metrics/MethodLength
class CreateCampaignAudienceImports < ActiveRecord::Migration[7.1]
  def up
    create_table :campaign_audience_imports do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :inbox, null: false, foreign_key: { on_delete: :cascade }
      t.references :created_by, null: true, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :token, null: false
      t.string :source_filename, null: false
      t.string :default_country, null: false
      t.integer :status, null: false, default: 0
      t.string :processing_error
      t.integer :total_rows, null: false, default: 0
      t.integer :recipient_count, null: false, default: 0
      t.integer :created_count, null: false, default: 0
      t.integer :existing_count, null: false, default: 0
      t.integer :duplicate_count, null: false, default: 0
      t.integer :invalid_count, null: false, default: 0
      t.integer :conflict_count, null: false, default: 0
      t.jsonb :error_samples, null: false, default: []
      t.datetime :expires_at, null: false
      t.datetime :claimed_at
      t.timestamps
    end

    add_index :campaign_audience_imports, :token, unique: true
    add_index :campaign_audience_imports, [:account_id, :expires_at]
    add_index :campaign_audience_imports, [:account_id, :status]

    create_table :campaign_audience_recipients do |t|
      t.references :campaign_audience_import,
                   null: false,
                   foreign_key: { on_delete: :cascade },
                   index: { name: 'idx_campaign_audience_recipients_on_import' }
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :contact, null: true, foreign_key: { on_delete: :nullify }
      t.string :normalized_phone_number, null: false
      t.integer :source_row, null: false
      t.boolean :contact_created, null: false, default: false
      t.timestamps
    end

    add_index :campaign_audience_recipients,
              [:campaign_audience_import_id, :contact_id],
              unique: true,
              name: 'idx_campaign_audience_recipients_import_contact'
    add_index :campaign_audience_recipients,
              [:campaign_audience_import_id, :normalized_phone_number],
              unique: true,
              name: 'idx_campaign_audience_recipients_import_phone'

    add_reference :campaigns,
                  :campaign_audience_import,
                  null: true,
                  foreign_key: { on_delete: :nullify },
                  index: { unique: true, name: 'idx_campaigns_on_audience_import' }
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'campaign audience snapshots must be retained during code rollback'
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/MethodLength
