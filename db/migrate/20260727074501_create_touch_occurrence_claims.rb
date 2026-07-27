class CreateTouchOccurrenceClaims < ActiveRecord::Migration[7.0]
  def change
    create_table :touch_occurrence_claims do |t|
      t.references :account, null: false, foreign_key: true
      t.references :touch_plan_enrollment, null: false, foreign_key: true
      t.references :reminder, foreign_key: true
      t.string :step_key, null: false
      t.string :occurrence_key, null: false
      t.datetime :due_at, null: false
      t.string :status, null: false, default: 'claimed'
      t.datetime :claimed_at, null: false
      t.datetime :materialized_at
      t.text :last_error
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :touch_occurrence_claims, [:touch_plan_enrollment_id, :occurrence_key],
              unique: true, name: 'idx_touch_occurrence_claims_on_enrollment_occurrence'
    add_index :touch_occurrence_claims, :reminder_id,
              unique: true, where: 'reminder_id IS NOT NULL', name: 'idx_touch_occurrence_claims_on_unique_reminder'
    add_index :touch_occurrence_claims, [:status, :claimed_at], name: 'idx_touch_occurrence_claims_stale'
  end
end
