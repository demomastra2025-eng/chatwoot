# frozen_string_literal: true

module Scheduling::AppointmentDialogContextSql
  private

  def conversation_context_rows_sql
    [
      direct_conversation_context_sql,
      contact_conversation_context_sql
    ].join(' UNION ALL ')
  end

  def communication_thread_context_rows_sql
    [
      contact_thread_context_sql,
      conversation_thread_context_sql
    ].join(' UNION ALL ')
  end

  def direct_conversation_context_sql
    <<~SQL.squish
      SELECT scheduling_appointments.id AS appointment_id,
             scheduling_appointments.conversation_id AS conversation_id,
             scheduling_appointments.status
      FROM scheduling_appointments
      WHERE scheduling_appointments.account_id = :account_id
        AND scheduling_appointments.conversation_id IS NOT NULL
    SQL
  end

  def contact_conversation_context_sql
    <<~SQL.squish
      SELECT scheduling_appointments.id AS appointment_id,
             conversations.id AS conversation_id,
             scheduling_appointments.status
      FROM scheduling_appointments
      INNER JOIN conversations
        ON conversations.contact_id = scheduling_appointments.contact_id
       AND conversations.account_id = :account_id
      WHERE scheduling_appointments.account_id = :account_id
        AND scheduling_appointments.contact_id IS NOT NULL
    SQL
  end

  def contact_thread_context_sql
    <<~SQL.squish
      SELECT scheduling_appointments.id AS appointment_id,
             communication_threads.id AS communication_thread_id,
             scheduling_appointments.status
      FROM scheduling_appointments
      INNER JOIN communication_threads
        ON communication_threads.contact_id = scheduling_appointments.contact_id
       AND communication_threads.account_id = :account_id
      WHERE scheduling_appointments.account_id = :account_id
        AND scheduling_appointments.contact_id IS NOT NULL
    SQL
  end

  def conversation_thread_context_sql
    <<~SQL.squish
      SELECT scheduling_appointments.id AS appointment_id,
             communication_thread_conversations.communication_thread_id AS communication_thread_id,
             scheduling_appointments.status
      FROM scheduling_appointments
      INNER JOIN communication_thread_conversations
        ON communication_thread_conversations.conversation_id = scheduling_appointments.conversation_id
       AND communication_thread_conversations.account_id = :account_id
      WHERE scheduling_appointments.account_id = :account_id
        AND scheduling_appointments.conversation_id IS NOT NULL
    SQL
  end
end
