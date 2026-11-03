# frozen_string_literal: true

class AddWaHistoricalDeliveryIndexToMessages < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  INDEX_NAME = 'index_messages_on_acc_inbox_created_for_wa_deliveries'
  WHERE_CLAUSE = "message_type IN (1, 3) AND status IN (1, 2) AND private = false AND source_id IS NOT NULL AND source_id <> ''"

  def up
    previous_lock_timeout = select_value('SHOW lock_timeout')
    execute "SET lock_timeout = '4s'"
    table = "#{select_value('SELECT current_schema()')}.messages"
    ensure_known_index_or_absent!
    add_index table,
              %i[account_id inbox_id created_at id updated_at],
              where: WHERE_CLAUSE,
              name: INDEX_NAME,
              algorithm: :concurrently,
              if_not_exists: true
    definition = delivery_index_definition
    unless known_delivery_index?(definition) && definition.values_at('indisvalid', 'indisready', 'indislive').all?
      raise ActiveRecord::MigrationError, 'delivery index is not ready and valid: explicit maintenance required'
    end
  ensure
    execute "SET lock_timeout = #{connection.quote(previous_lock_timeout)}" if previous_lock_timeout
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Retain the additive delivery index; rollback application source only.'
  end

  private

  def ensure_known_index_or_absent!
    return unless select_value("SELECT to_regclass(quote_ident(current_schema()) || '.#{INDEX_NAME}')")

    definition = delivery_index_definition
    return if known_delivery_index?(definition) && definition.values_at('indisvalid', 'indisready', 'indislive').all?

    raise ActiveRecord::MigrationError, 'unknown or invalid delivery index: explicit maintenance required'
  end

  def known_delivery_index?(definition)
    definition && definition['known_shape'] && definition['predicate'].to_s.gsub(/::text|[\s()]/, '') ==
      "message_type=ANYARRAY[1,3]ANDstatus=ANYARRAY[1,2]ANDprivate=falseANDsource_idISNOTNULLANDsource_id<>''"
  end

  def delivery_index_definition
    select_one <<~SQL.squish
      SELECT idx.indisvalid, idx.indisready, idx.indislive, pg_get_expr(idx.indpred, idx.indrelid) AS predicate,
        am.amname = 'btree' AND NOT idx.indisunique AND NOT idx.indisexclusion
        AND idx.indnkeyatts = 5 AND idx.indnatts = 5 AND idx.indexprs IS NULL
        AND idx.indoption::text = '0 0 0 0 0' AND idx.indcollation::text = '0 0 0 0 0'
        AND NOT EXISTS (SELECT 1 FROM unnest(idx.indclass) AS opclass(oid)
          JOIN pg_opclass opc ON opc.oid = opclass.oid WHERE NOT opc.opcdefault)
        AND ARRAY(SELECT attr.attname::text FROM unnest(idx.indkey) WITH ORDINALITY AS key(attnum, position)
          JOIN pg_attribute attr ON attr.attrelid = idx.indrelid AND attr.attnum = key.attnum ORDER BY key.position)
          = ARRAY['account_id', 'inbox_id', 'created_at', 'id', 'updated_at']::text[] AS known_shape
      FROM pg_index idx JOIN pg_class index_relation ON index_relation.oid = idx.indexrelid
      JOIN pg_am am ON am.oid = index_relation.relam
      WHERE idx.indexrelid = to_regclass(quote_ident(current_schema()) || '.#{INDEX_NAME}')
        AND idx.indrelid = to_regclass(quote_ident(current_schema()) || '.messages')
    SQL
  end
end
