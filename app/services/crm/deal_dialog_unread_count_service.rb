# frozen_string_literal: true

class Crm::DealDialogUnreadCountService
  include Crm::DealDialogContextSql

  attr_reader :account, :conversation_scope, :communication_thread_scope

  def initialize(account:, conversation_scope: nil, communication_thread_scope: nil)
    @account = account
    @conversation_scope = conversation_scope
    @communication_thread_scope = communication_thread_scope
  end

  def conversation_pipeline_counts
    conversation_counts_for(:pipeline)
  end

  def conversation_stage_counts
    conversation_counts_for(:stage)
  end

  def communication_thread_pipeline_counts
    communication_thread_counts_for(:pipeline)
  end

  def communication_thread_stage_counts
    communication_thread_counts_for(:stage)
  end

  private

  def conversation_counts_for(dimension)
    grouped_counts(
      context_sql: conversation_context_rows_sql,
      visible_sql: visible_conversation_ids_sql,
      record_id_column: 'conversation_id',
      dimension: dimension
    )
  end

  def communication_thread_counts_for(dimension)
    grouped_counts(
      context_sql: communication_thread_context_rows_sql,
      visible_sql: visible_communication_thread_ids_sql,
      record_id_column: 'communication_thread_id',
      dimension: dimension
    )
  end

  def grouped_counts(context_sql:, visible_sql:, record_id_column:, dimension:)
    key_column = dimension == :pipeline ? 'pipeline_id' : 'stage_id'

    rows_to_hash(
      connection.select_all(
        sanitized_sql(grouped_counts_sql(context_sql, visible_sql, record_id_column, dimension, key_column))
      )
    )
  end

  def grouped_counts_sql(context_sql, visible_sql, record_id_column, dimension, key_column)
    <<~SQL.squish
      SELECT crm_context.#{key_column} AS id,
             COUNT(DISTINCT crm_context.#{record_id_column}) AS count
      FROM (#{context_sql}) crm_context
      INNER JOIN (#{visible_sql}) visible_records
        ON visible_records.id = crm_context.#{record_id_column}
      #{dimension_join_sql(dimension, key_column)}
      GROUP BY crm_context.#{key_column}
    SQL
  end

  def dimension_join_sql(dimension, key_column)
    return pipeline_join_sql(key_column) if dimension == :pipeline

    stage_join_sql(key_column)
  end

  def pipeline_join_sql(key_column)
    <<~SQL.squish
      INNER JOIN crm_pipelines crm_dimension
        ON crm_dimension.id = crm_context.#{key_column}
       AND crm_dimension.account_id = :account_id
       AND crm_dimension.active = TRUE
      INNER JOIN crm_stages crm_active_stage
        ON crm_active_stage.id = crm_context.stage_id
       AND crm_active_stage.account_id = :account_id
       AND crm_active_stage.active = TRUE
    SQL
  end

  def stage_join_sql(key_column)
    <<~SQL.squish
      INNER JOIN crm_stages crm_dimension
        ON crm_dimension.id = crm_context.#{key_column}
       AND crm_dimension.account_id = :account_id
       AND crm_dimension.active = TRUE
    SQL
  end

  def rows_to_hash(rows)
    rows.each_with_object({}) do |row, result|
      count = row['count'].to_i
      result[row['id'].to_s] = count if count.positive?
    end
  end

  def visible_conversation_ids_sql
    conversation_scope
      .except(:order, :limit, :offset)
      .reselect('conversations.id')
      .distinct
      .to_sql
  end

  def visible_communication_thread_ids_sql
    communication_thread_scope
      .except(:order, :limit, :offset)
      .reselect('communication_threads.id')
      .distinct
      .to_sql
  end

  def sanitized_sql(sql)
    ActiveRecord::Base.sanitize_sql_array([sql, { account_id: account.id }])
  end

  def connection
    ActiveRecord::Base.connection
  end
end
