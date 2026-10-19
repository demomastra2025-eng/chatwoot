# frozen_string_literal: true

class AddScalingIndexesForTelephonyAndStorage < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def up
    add_telephony_indexes
    add_reminder_and_thread_indexes
  end

  def down
    remove_index :communication_thread_conversations, name: 'index_ctc_on_account_conversation_thread', if_exists: true
    remove_index :reminders, name: 'index_reminders_on_pending_scheduled_at', if_exists: true
    remove_index :telephony_events, name: 'index_telephony_events_on_failed_status_created_at', if_exists: true
    remove_index :telephony_call_sessions, name: 'index_telephony_call_sessions_on_provider_call_sid', if_exists: true
    remove_index :telephony_call_sessions, name: 'index_telephony_call_sessions_on_external_call_ref', if_exists: true
    remove_index :telephony_call_sessions, name: 'index_telephony_call_sessions_on_account_with_recordings', if_exists: true
    remove_index :telephony_call_sessions, name: 'index_telephony_call_sessions_on_active_status_started_at', if_exists: true
  end

  private

  def add_telephony_indexes
    add_index :telephony_call_sessions, %i[account_id started_at],
              where: "status IN ('ringing', 'answered', 'in_progress')",
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
end
