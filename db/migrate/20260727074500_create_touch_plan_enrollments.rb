class CreateTouchPlanEnrollments < ActiveRecord::Migration[7.0]
  def change
    create_table :touch_plan_enrollments do |t|
      t.references :account, null: false, foreign_key: true
      t.references :reminder_group, foreign_key: true
      t.references :remindable, polymorphic: true
      t.string :status, null: false, default: 'active'
      t.jsonb :plan_snapshot, null: false, default: []
      t.string :plan_digest, null: false
      t.datetime :next_due_at
      t.datetime :activated_at, null: false
      t.string :idempotency_key, null: false
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_indexes
  end

  private

  def add_indexes
    add_index :touch_plan_enrollments, [:status, :next_due_at], name: 'idx_touch_plan_enrollments_due'
    add_index :touch_plan_enrollments, [:remindable_type, :remindable_id, :status],
              name: 'idx_touch_plan_enrollments_on_remindable_status'
    add_index :touch_plan_enrollments, [:account_id, :idempotency_key],
              unique: true, name: 'idx_touch_plan_enrollments_on_account_idempotency'
    add_index :touch_plan_enrollments,
              [:account_id, :reminder_group_id, :remindable_type, :remindable_id],
              unique: true,
              where: "status IN ('active', 'paused')",
              name: 'idx_touch_plan_enrollments_one_open_plan'
  end
end
