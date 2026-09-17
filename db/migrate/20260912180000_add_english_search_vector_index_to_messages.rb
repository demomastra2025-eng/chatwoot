class AddEnglishSearchVectorIndexToMessages < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  INDEX_NAME = 'index_messages_on_english_search_vector'.freeze
  EXPECTED_EXPRESSION = "to_tsvector('english'::regconfig, COALESCE(content, ''::text))".freeze

  def up
    ensure_english_default!
    index = existing_index
    return if index && index_valid?(index) && index.fetch('definition').include?(EXPECTED_EXPRESSION)

    connection.execute "DROP INDEX CONCURRENTLY IF EXISTS #{INDEX_NAME}" if index

    connection.execute <<~SQL.squish
      CREATE INDEX CONCURRENTLY #{INDEX_NAME}
      ON messages
      USING gin (#{EXPECTED_EXPRESSION})
    SQL
  end

  def down
    connection.execute "DROP INDEX CONCURRENTLY IF EXISTS #{INDEX_NAME}"
  end

  private

  def ensure_english_default!
    english_default = connection.select_value(
      "SELECT current_setting('default_text_search_config')::regconfig = 'english'::regconfig"
    )
    return if ActiveModel::Type::Boolean.new.cast(english_default)

    raise ActiveRecord::MigrationError, 'default_text_search_config must be English before installing the message search index'
  end

  def existing_index
    connection.select_one(<<~SQL.squish)
      SELECT index_definition.indisvalid AS valid, pg_get_indexdef(index_definition.indexrelid) AS definition
      FROM pg_index index_definition
      JOIN pg_class index_relation ON index_relation.oid = index_definition.indexrelid
      JOIN pg_namespace index_namespace ON index_namespace.oid = index_relation.relnamespace
      WHERE index_relation.relname = #{connection.quote(INDEX_NAME)}
        AND index_namespace.nspname = ANY (current_schemas(false))
    SQL
  end

  def index_valid?(index)
    ActiveModel::Type::Boolean.new.cast(index.fetch('valid'))
  end
end
