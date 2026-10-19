# frozen_string_literal: true

class AddScalingIndexesForTelephonyAndStorage < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  ACTIVE_CALL_STATUSES_SQL = %w[
    created ringing connecting in_progress queued initiated
    answered in-progress inprogress session_started decision_received
    operator_ringing operator_answered
  ].map { |s| "'#{s}'" }.join(', ').freeze

  def up
    add_telephony_session_indexes
    add_telephony_aux_indexes
    add_reminder_and_thread_indexes
    add_medelement_and_whatsapp_indexes
    add_contact_and_thread_statistics
  end

  def down
    execute 'DROP STATISTICS IF EXISTS stats_communication_threads_account_status'
    execute 'DROP STATISTICS IF EXISTS stats_conversations_account_status'
    remove_index :contacts, name: 'index_contacts_on_account_id_and_id', if_exists: true
    remove_index :whatsapp_pending_message_mutations, name: 'index_wa_pending_mutations_on_unscrubbed_exhausted', if_exists: true
    remove_index :medelement_sync_runs, name: 'index_medelement_sync_runs_on_phase_results', if_exists: true
    remove_index :medelement_sync_runs, name: 'index_medelement_sync_runs_on_hook_completed_at', if_exists: true
    remove_index :communication_thread_conversations, name: 'index_ctc_on_account_conversation_thread', if_exists: true
    remove_index :reminders, name: 'index_reminders_on_pending_scheduled_at', if_exists: true
    remove_index :telephony_events, name: 'index_telephony_events_on_failed_status_created_at', if_exists: true
    remove_index :telephony_call_sessions, name: 'index_telephony_call_sessions_on_unanswered_with_actor', if_exists: true
    remove_index :telephony_call_sessions, name: 'index_telephony_call_sessions_on_provider_call_sid', if_exists: true
    remove_index :telephony_call_sessions, name: 'index_telephony_call_sessions_on_external_call_ref', if_exists: true
    remove_index :telephony_call_sessions, name: 'index_telephony_call_sessions_on_account_with_recordings', if_exists: true
    remove_index :telephony_call_sessions, name: 'index_telephony_call_sessions_on_active_status_started_at', if_exists: true
  end

  private

  def add_telephony_session_indexes
    add_index :telephony_call_sessions, %i[account_id started_at],
              where: "status IN (#{ACTIVE_CALL_STATUSES_SQL})",
              name: 'index_telephony_call_sessions_on_active_status_started_at',
              algorithm: :concurrently, if_not_exists: true
    add_index :telephony_call_sessions, %i[account_id id],
              where: "recording_ref IS NOT NULL OR (metadata ? 'retained_original') OR (metadata ? 'trash')",
              name: 'index_telephony_call_sessions_on_account_with_recordings',
              algorithm: :concurrently, if_not_exists: true
    add_index :telephony_call_sessions, :external_call_ref,
              name: 'index_telephony_call_sessions_on_external_call_ref',
              algorithm: :concurrently, if_not_exists: true
    add_index :telephony_call_sessions, :provider_call_sid,
              where: 'provider_call_sid IS NOT NULL',
              name: 'index_telephony_call_sessions_on_provider_call_sid',
              algorithm: :concurrently, if_not_exists: true
  end

  def add_telephony_aux_indexes
    add_index :telephony_call_sessions, :id,
              where: "answered_at IS NULL AND answered_by IS NOT NULL AND answered_by <> ''",
              name: 'index_telephony_call_sessions_on_unanswered_with_actor',
              algorithm: :concurrently, if_not_exists: true
    add_index :telephony_events, %i[created_at id],
              where: "status = 'failed'",
              name: 'index_telephony_events_on_failed_status_created_at',
              algorithm: :concurrently, if_not_exists: true
  end

  def add_reminder_and_thread_indexes
    add_index :reminders, %i[scheduled_at created_at id],
              where: 'status = 1',
              name: 'index_reminders_on_pending_scheduled_at',
              algorithm: :concurrently, if_not_exists: true
    add_index :communication_thread_conversations,
              %i[account_id conversation_id communication_thread_id],
              name: 'index_ctc_on_account_conversation_thread',
              algorithm: :concurrently, if_not_exists: true
  end

  def add_medelement_and_whatsapp_indexes
    add_index :medelement_sync_runs, %i[hook_id completed_at id],
              name: 'index_medelement_sync_runs_on_hook_completed_at',
              algorithm: :concurrently, if_not_exists: true
    add_index :medelement_sync_runs, :phase_results,
              using: :gin,
              name: 'index_medelement_sync_runs_on_phase_results',
              algorithm: :concurrently, if_not_exists: true
    add_index :whatsapp_pending_message_mutations, %i[terminal_at id],
              where: "status = 'exhausted' AND payload_scrubbed_at IS NULL",
              name: 'index_wa_pending_mutations_on_unscrubbed_exhausted',
              algorithm: :concurrently, if_not_exists: true
  end

  def add_contact_and_thread_statistics
    add_index :contacts, %i[account_id id],
              name: 'index_contacts_on_account_id_and_id',
              algorithm: :concurrently, if_not_exists: true
    execute <<~SQL.squish
      CREATE STATISTICS IF NOT EXISTS stats_conversations_account_status (dependencies, ndistinct, mcv)
      ON account_id, status FROM conversations
    SQL
    execute <<~SQL.squish
      CREATE STATISTICS IF NOT EXISTS stats_communication_threads_account_status (dependencies, ndistinct, mcv)
      ON account_id, status FROM communication_threads
    SQL
  end
end
