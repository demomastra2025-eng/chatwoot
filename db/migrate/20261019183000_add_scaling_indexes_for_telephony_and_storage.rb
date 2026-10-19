# frozen_string_literal: true

class AddScalingIndexesForTelephonyAndStorage < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  ACTIVE_CALL_WHERE = "status NOT IN ('completed', 'failed', 'no_answer', 'busy', 'canceled', 'rejected', 'missed')"
  RECORDING_SESSION_WHERE = "(NULLIF(recording_ref, '') IS NOT NULL OR (metadata -> 'trash') IS NOT NULL " \
                            "OR (metadata #> '{recording,retained_original}') IS NOT NULL)"

  def up
    add_index :telephony_call_sessions,
              %i[provider status started_at created_at],
              where: ACTIVE_CALL_WHERE,
              name: 'index_telephony_call_sessions_on_active_status_started_at',
              algorithm: :concurrently,
              if_not_exists: true

    add_index :telephony_call_sessions,
              %i[account_id id],
              where: RECORDING_SESSION_WHERE,
              name: 'index_telephony_call_sessions_on_account_with_recordings',
              algorithm: :concurrently,
              if_not_exists: true

    add_index :telephony_call_sessions,
              :external_call_ref,
              name: 'index_telephony_call_sessions_on_external_call_ref',
              algorithm: :concurrently,
              if_not_exists: true

    add_index :telephony_call_sessions,
              :provider_call_sid,
              where: 'provider_call_sid IS NOT NULL',
              name: 'index_telephony_call_sessions_on_provider_call_sid',
              algorithm: :concurrently,
              if_not_exists: true

    add_index :telephony_events,
              %i[created_at id],
              where: "status = 'failed'",
              name: 'index_telephony_events_on_failed_status_created_at',
              algorithm: :concurrently,
              if_not_exists: true
  end

  def down
    remove_index :telephony_events, name: 'index_telephony_events_on_failed_status_created_at', if_exists: true
    remove_index :telephony_call_sessions, name: 'index_telephony_call_sessions_on_provider_call_sid', if_exists: true
    remove_index :telephony_call_sessions, name: 'index_telephony_call_sessions_on_external_call_ref', if_exists: true
    remove_index :telephony_call_sessions, name: 'index_telephony_call_sessions_on_account_with_recordings', if_exists: true
    remove_index :telephony_call_sessions, name: 'index_telephony_call_sessions_on_active_status_started_at', if_exists: true
  end
end
