class AddPendingAiUsageIndexToMessages < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def up
    previous_lock_timeout = select_value('SHOW lock_timeout')
    execute "SET lock_timeout = '4s'"
    repair_known_invalid_index
    add_index :messages, [:ai_usage_retry_at, :id], where: 'ai_usage_pending = true', name: 'idx_messages_pending_ai_usage', algorithm: :concurrently,
                                                    if_not_exists: true
    definition = pending_index_definition
    unless known_pending_index?(definition) && definition['indisvalid'] && definition['indisready'] && definition['indislive']
      raise ActiveRecord::MigrationError, 'pending AI usage index is not ready and valid'
    end
  ensure
    execute "SET lock_timeout = #{connection.quote(previous_lock_timeout)}" if previous_lock_timeout
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Retain the usage index with AI history; rollback application source only.'
  end

  private

  def repair_known_invalid_index
    return unless select_value("SELECT to_regclass(quote_ident(current_schema()) || '.idx_messages_pending_ai_usage')")

    definition = pending_index_definition
    raise ActiveRecord::MigrationError, 'unknown pending AI usage index shape: explicit maintenance required' unless known_pending_index?(definition)

    remove_index :messages, name: 'idx_messages_pending_ai_usage', algorithm: :concurrently unless definition['indisvalid']
  end

  def known_pending_index?(definition)
    definition && definition['known_shape'] && definition['predicate'].to_s.gsub(/[\s()]/, '') == 'ai_usage_pending=true'
  end

  def pending_index_definition
    select_one <<~SQL.squish
      SELECT idx.indisvalid, idx.indisready, idx.indislive, pg_get_expr(idx.indpred, idx.indrelid) AS predicate,
        am.amname = 'btree' AND NOT idx.indisunique AND NOT idx.indisexclusion
        AND idx.indnkeyatts = 2 AND idx.indnatts = 2 AND idx.indexprs IS NULL
        AND idx.indoption::text = '0 0' AND idx.indcollation::text = '0 0'
        AND NOT EXISTS (SELECT 1 FROM unnest(idx.indclass) AS opclass(oid)
          JOIN pg_opclass opc ON opc.oid = opclass.oid WHERE NOT opc.opcdefault)
        AND ARRAY(SELECT attr.attname::text FROM unnest(idx.indkey) WITH ORDINALITY AS key(attnum, position)
          JOIN pg_attribute attr ON attr.attrelid = idx.indrelid AND attr.attnum = key.attnum ORDER BY key.position)
          = ARRAY['ai_usage_retry_at', 'id']::text[] AS known_shape
      FROM pg_index idx JOIN pg_class index_relation ON index_relation.oid = idx.indexrelid
      JOIN pg_am am ON am.oid = index_relation.relam
      WHERE idx.indexrelid = to_regclass(quote_ident(current_schema()) || '.idx_messages_pending_ai_usage')
        AND idx.indrelid = to_regclass(quote_ident(current_schema()) || '.messages')
    SQL
  end
end
