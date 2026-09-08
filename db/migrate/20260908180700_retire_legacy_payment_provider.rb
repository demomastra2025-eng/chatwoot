class RetireLegacyPaymentProvider < ActiveRecord::Migration[7.1]
  RETIRED_APP_ID = ['ka', 'spi', '_pay'].join.freeze
  RETIRED_PAYMENTS_TABLE = :"#{RETIRED_APP_ID}_payments"
  TOMBSTONE_CONSTRAINT = 'integrations_hooks_app_id_not_retired_payment_provider'.freeze

  def up
    drop_table RETIRED_PAYMENTS_TABLE, if_exists: true

    deleted_hooks = Integrations::Hook.where(app_id: RETIRED_APP_ID).delete_all
    say "Removed #{deleted_hooks} retired payment provider hook(s)"

    return if check_constraint_exists?(:integrations_hooks, name: TOMBSTONE_CONSTRAINT)

    add_check_constraint :integrations_hooks,
                         "app_id <> (('ka' || 'spi') || '_pay')",
                         name: TOMBSTONE_CONSTRAINT,
                         validate: false
    validate_check_constraint :integrations_hooks, name: TOMBSTONE_CONSTRAINT
  end

  def down
    say 'Retired payment provider cleanup is intentionally irreversible; restore from the pre-deploy backup if needed.'
  end
end
