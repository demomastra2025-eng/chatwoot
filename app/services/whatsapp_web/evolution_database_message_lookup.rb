class WhatsappWeb::EvolutionDatabaseMessageLookup
  DEFAULT_SAME_DB_SCHEMA = 'evolution_api'.freeze
  SAFE_IDENTIFIER_REGEX = /\A[a-zA-Z_][a-zA-Z0-9_]*\z/

  def initialize(database_url: ENV.fetch('EVOLUTION_DATABASE_URL', nil))
    @database_url = database_url.to_s.strip.presence
  end

  def lookup(source_id:, instance_name: nil)
    return if source_id.blank?

    if @database_url.present?
      lookup_via_external_url(source_id.to_s, instance_name.to_s.presence)
    else
      lookup_via_same_postgres(source_id.to_s, instance_name.to_s.presence)
    end
  rescue StandardError => e
    Rails.logger.info("[WHATSAPP WEB] Evolution SQL lookup skipped for #{source_id}: #{e.class}: #{e.message}")
    nil
  end

  private

  def lookup_via_external_url(source_id, instance_name)
    clean_url, schema = extract_connection_url_and_schema(@database_url)
    conn = PG.connect(clean_url)
    conn.exec('SET default_transaction_read_only = on')
    return unless pg_table_exists?(conn, schema, 'Message')

    has_instance = instance_name.present? && pg_table_exists?(conn, schema, 'Instance')
    sql, binds = build_lookup_query(schema, source_id, instance_name, has_instance: has_instance)
    result = conn.exec_params(sql, binds)
    hydrate_row(result.first)
  ensure
    conn&.close
  end

  def lookup_via_same_postgres(source_id, instance_name)
    ar_conn = ActiveRecord::Base.connection
    return unless ar_table_exists?(ar_conn, DEFAULT_SAME_DB_SCHEMA, 'Message')

    has_instance = instance_name.present? && ar_table_exists?(ar_conn, DEFAULT_SAME_DB_SCHEMA, 'Instance')
    sql, binds = build_lookup_query(DEFAULT_SAME_DB_SCHEMA, source_id, instance_name, has_instance: has_instance)
    result = ar_conn.exec_query(sql, 'EvolutionMessageLookup', binds)
    hydrate_row(result.first)
  end

  def extract_connection_url_and_schema(raw_url)
    uri = URI.parse(raw_url)
    params = Rack::Utils.parse_query(uri.query)
    schema = validate_identifier!(params.delete('schema').presence || 'public')
    uri.query = params.present? ? URI.encode_www_form(params) : nil
    [uri.to_s, schema]
  end

  def validate_identifier!(identifier)
    str = identifier.to_s
    raise ArgumentError, "Unsafe SQL schema identifier: #{str.inspect}" unless str.match?(SAFE_IDENTIFIER_REGEX)

    str
  end

  def pg_table_exists?(conn, schema, table_name)
    res = conn.exec_params(
      'SELECT 1 FROM information_schema.tables WHERE table_schema = $1 AND table_name = $2 LIMIT 1',
      [schema, table_name]
    )
    res.ntuples.positive?
  end

  def ar_table_exists?(ar_conn, schema, table_name)
    res = ar_conn.exec_query(
      'SELECT 1 FROM information_schema.tables WHERE table_schema = $1 AND table_name = $2 LIMIT 1',
      'EvolutionTableCheck',
      [schema, table_name]
    )
    res.rows.any?
  end

  def build_lookup_query(schema, source_id, instance_name, has_instance:)
    quoted_schema = %("#{validate_identifier!(schema)}")
    return instance_lookup_query(quoted_schema, source_id, instance_name) if has_instance

    unscoped_lookup_query(quoted_schema, source_id)
  end

  def instance_lookup_query(quoted_schema, source_id, instance_name)
    sql = <<~SQL.squish
      SELECT m."key", m."message", m."messageType", m."messageTimestamp"
      FROM #{quoted_schema}."Message" m
      LEFT JOIN #{quoted_schema}."Instance" i ON i."id" = m."instanceId"
      WHERE m."key"->>'id' = $1
      ORDER BY CASE WHEN i."name" = $2 THEN 0 ELSE 1 END, m."messageTimestamp" DESC NULLS LAST
      LIMIT 1
    SQL
    [sql, [source_id, instance_name]]
  end

  def unscoped_lookup_query(quoted_schema, source_id)
    sql = <<~SQL.squish
      SELECT m."key", m."message", m."messageType", m."messageTimestamp"
      FROM #{quoted_schema}."Message" m
      WHERE m."key"->>'id' = $1
      ORDER BY m."messageTimestamp" DESC NULLS LAST
      LIMIT 1
    SQL
    [sql, [source_id]]
  end

  def hydrate_row(row)
    return if row.blank?

    {
      'key' => parse_json_column(row['key']),
      'message' => parse_json_column(row['message']),
      'messageType' => row['messageType'],
      'messageTimestamp' => row['messageTimestamp']&.to_i
    }.compact
  end

  def parse_json_column(value)
    return value if value.is_a?(Hash)
    return JSON.parse(value) if value.is_a?(String) && value.present?

    nil
  rescue JSON::ParserError
    nil
  end
end
