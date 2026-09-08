class CreateBillingAuditEvents < ActiveRecord::Migration[7.1]
  AGENTS_LIMIT_CONSTRAINT = <<~SQL.squish
    CASE WHEN limits ? 'agents'
      THEN jsonb_typeof(limits -> 'agents') = 'number' AND (limits ->> 'agents')::numeric >= 0
      ELSE TRUE
    END
  SQL
  STORAGE_LIMIT_CONSTRAINT = <<~SQL.squish
    CASE WHEN limits ? 'storage_bytes'
      THEN jsonb_typeof(limits -> 'storage_bytes') = 'number' AND (limits ->> 'storage_bytes')::numeric >= 0
      ELSE TRUE
    END
  SQL

  def up
    create_audit_events_table
    add_allocation_constraints
    create_audit_event_triggers
  end

  def down
    remove_check_constraint :billing_entitlement_allocations, name: 'chk_billing_allocations_storage_non_negative'
    remove_check_constraint :billing_entitlement_allocations, name: 'chk_billing_allocations_agents_non_negative'
    remove_check_constraint :billing_entitlement_allocations, name: 'chk_billing_allocations_limits_object'
    drop_table :billing_audit_events
    execute 'DROP FUNCTION IF EXISTS billing_audit_events_before_update()'
    execute 'DROP FUNCTION IF EXISTS billing_audit_events_before_delete()'
  end

  private

  def create_audit_events_table
    create_table :billing_audit_events do |t|
      t.references :billing_account, null: false, foreign_key: true
      t.references :super_admin, type: :integer, null: true,
                                 foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :action, null: false
      t.jsonb :details, null: false, default: {}
      t.datetime :occurred_at, null: false, default: -> { 'CURRENT_TIMESTAMP' }
      t.timestamps
    end
    add_index :billing_audit_events, [:billing_account_id, :occurred_at],
              name: 'idx_billing_audit_events_account_time'
    add_check_constraint :billing_audit_events, "jsonb_typeof(details) = 'object'",
                         name: 'chk_billing_audit_events_details_object'
  end

  def add_allocation_constraints
    add_check_constraint :billing_entitlement_allocations, "jsonb_typeof(limits) = 'object'",
                         name: 'chk_billing_allocations_limits_object'
    add_check_constraint :billing_entitlement_allocations, AGENTS_LIMIT_CONSTRAINT,
                         name: 'chk_billing_allocations_agents_non_negative'
    add_check_constraint :billing_entitlement_allocations, STORAGE_LIMIT_CONSTRAINT,
                         name: 'chk_billing_allocations_storage_non_negative'
  end

  def create_audit_event_triggers
    create_trigger('billing_audit_events_before_update').on('billing_audit_events').before(:update).for_each(:row) do
      <<~SQL.squish
        IF OLD.super_admin_id IS NOT NULL
          AND NEW.super_admin_id IS NULL
          AND to_jsonb(NEW) - 'super_admin_id' = to_jsonb(OLD) - 'super_admin_id'
        THEN
          RETURN NEW;
        END IF;
        RAISE EXCEPTION 'billing audit events are immutable';
      SQL
    end
    create_trigger('billing_audit_events_before_delete').on('billing_audit_events').before(:delete).for_each(:row) do
      "RAISE EXCEPTION 'billing audit events are immutable';"
    end
  end
end
