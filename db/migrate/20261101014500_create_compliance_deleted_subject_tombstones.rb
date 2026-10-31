# frozen_string_literal: true

class CreateComplianceDeletedSubjectTombstones < ActiveRecord::Migration[7.1]
  def change
    create_table :compliance_deleted_subject_tombstones do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.string :identifier_kind, null: false
      t.string :identifier_hmac, null: false
      t.string :certificate_uid, null: false
      t.string :reason, null: false, default: 'subject_request'
      t.datetime :erased_at, null: false
      t.datetime :revoked_at
      t.datetime :remote_synced_at
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :compliance_deleted_subject_tombstones,
              %i[account_id identifier_kind identifier_hmac],
              unique: true,
              name: 'idx_compliance_tombstones_unique_lookup'
    add_index :compliance_deleted_subject_tombstones,
              %i[account_id certificate_uid],
              name: 'idx_compliance_tombstones_certificate'
  end
end
