# frozen_string_literal: true

class Scheduling::AppointmentDialogCountService
  include Scheduling::AppointmentDialogContextSql

  attr_reader :account, :conversation_scope, :communication_thread_scope

  def initialize(account:, conversation_scope: nil, communication_thread_scope: nil)
    @account = account
    @conversation_scope = conversation_scope
    @communication_thread_scope = communication_thread_scope
  end

  def conversation_status_counts
    return {} if conversation_scope.blank?

    status_counts(
      context_rows_sql: conversation_context_rows_sql,
      dialog_column: 'conversation_id',
      dialog_scope: conversation_scope,
      table_name: 'conversations'
    )
  end

  def communication_thread_status_counts
    return {} if communication_thread_scope.blank?

    status_counts(
      context_rows_sql: communication_thread_context_rows_sql,
      dialog_column: 'communication_thread_id',
      dialog_scope: communication_thread_scope,
      table_name: 'communication_threads'
    )
  end

  private

  def status_counts(context_rows_sql:, dialog_column:, dialog_scope:, table_name:)
    counts = grouped_status_counts(
      context_rows_sql: context_rows_sql,
      dialog_column: dialog_column,
      dialog_scope: dialog_scope,
      table_name: table_name
    )
    any_count = dialog_count(
      context_rows_sql: context_rows_sql,
      dialog_column: dialog_column,
      dialog_scope: dialog_scope,
      table_name: table_name
    )

    counts['any'] = any_count if any_count.positive?
    counts
  end

  def grouped_status_counts(context_rows_sql:, dialog_column:, dialog_scope:, table_name:)
    rows = connection.select_rows(
      status_count_sql(
        context_rows_sql: context_rows_sql,
        dialog_column: dialog_column,
        dialog_scope: dialog_scope,
        table_name: table_name
      )
    )

    rows.each_with_object({}) do |(status, count), result|
      result[status.to_s] = count.to_i if status.present?
    end
  end

  def dialog_count(context_rows_sql:, dialog_column:, dialog_scope:, table_name:)
    connection.select_value(
      dialog_count_sql(
        context_rows_sql: context_rows_sql,
        dialog_column: dialog_column,
        dialog_scope: dialog_scope,
        table_name: table_name
      )
    ).to_i
  end

  def status_count_sql(context_rows_sql:, dialog_column:, dialog_scope:, table_name:)
    safe_context_rows_sql = sanitize_sql(context_rows_sql, account_id: account.id)
    visible_dialogs_sql = dialog_scope.except(:select, :order, :limit, :offset)
                                      .reselect("#{table_name}.id")
                                      .distinct
                                      .to_sql

    <<~SQL.squish
      SELECT appointment_dialog_rows.status,
             COUNT(DISTINCT appointment_dialog_rows.#{dialog_column}) AS dialog_count
      FROM (#{safe_context_rows_sql}) appointment_dialog_rows
      INNER JOIN (#{visible_dialogs_sql}) visible_dialogs
        ON visible_dialogs.id = appointment_dialog_rows.#{dialog_column}
      WHERE appointment_dialog_rows.status IN (#{quoted_status_values})
      GROUP BY appointment_dialog_rows.status
    SQL
  end

  def dialog_count_sql(context_rows_sql:, dialog_column:, dialog_scope:, table_name:)
    safe_context_rows_sql = sanitize_sql(context_rows_sql, account_id: account.id)
    visible_dialogs_sql = dialog_scope.except(:select, :order, :limit, :offset)
                                      .reselect("#{table_name}.id")
                                      .distinct
                                      .to_sql

    <<~SQL.squish
      SELECT COUNT(DISTINCT appointment_dialog_rows.#{dialog_column}) AS dialog_count
      FROM (#{safe_context_rows_sql}) appointment_dialog_rows
      INNER JOIN (#{visible_dialogs_sql}) visible_dialogs
        ON visible_dialogs.id = appointment_dialog_rows.#{dialog_column}
      WHERE appointment_dialog_rows.status IN (#{quoted_status_values})
    SQL
  end

  def quoted_status_values
    Scheduling::Constants::APPOINTMENT_STATUSES.map do |status|
      connection.quote(status)
    end.join(', ')
  end

  def sanitize_sql(sql, bind_values)
    ActiveRecord::Base.send(:sanitize_sql_array, [sql, bind_values])
  end

  def connection
    ApplicationRecord.connection
  end
end
