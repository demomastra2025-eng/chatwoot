class ScopeLeadSubmissionDeduplicationToLeadForm < ActiveRecord::Migration[7.1]
  def up
    remove_index :lead_submissions, [:account_id, :external_ref], if_exists: true
    remove_index :lead_submissions, [:account_id, :idempotency_key], if_exists: true

    unless index_exists?(:lead_submissions, [:account_id, :lead_form_id, :external_ref], unique: true)
      add_index :lead_submissions,
                [:account_id, :lead_form_id, :external_ref],
                unique: true,
                where: 'external_ref IS NOT NULL',
                name: 'idx_lead_submissions_form_external_ref'
    end

    return if index_exists?(:lead_submissions, [:account_id, :lead_form_id, :idempotency_key], unique: true)

    add_index :lead_submissions,
              [:account_id, :lead_form_id, :idempotency_key],
              unique: true,
              where: 'idempotency_key IS NOT NULL',
              name: 'idx_lead_submissions_form_idempotency_key'
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          'Lead submission deduplication cannot be safely narrowed back to account scope after accepting per-form keys'
  end
end
