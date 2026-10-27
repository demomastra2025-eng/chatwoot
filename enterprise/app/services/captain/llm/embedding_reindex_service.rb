# The full re-embedding of everything that holds vectors (the FAQ, the answer cache, the help center articles, the knowledge chunks and
# the service catalog, see Captain::Llm::EmbeddingSources) with ONE embedding model, and the switch of CAPTAIN_EMBEDDING_MODEL to it.
# Vectors of two models cannot be compared, so the switch is one step:
#
#   1. the old vectors are written to a backup directory (Captain::Llm::EmbeddingBackup);
#   2. every text is embedded in memory, in batches. If anything fails here nothing has been written;
#   3. all vectors and their model name are stored in ONE database transaction, together with the CAPTAIN_EMBEDDING_MODEL setting.
#
# `rake onelink:embeddings:preview` is the dry run (no model call, no write), `status` shows which model made the vectors of each table,
# `apply` does the three steps (CONFIRM=yes) and `restore` puts the backup back. See lib/tasks/onelink_embeddings.rake.
class Captain::Llm::EmbeddingReindexService
  # Tokens per character measured for the Gemini tokenizer on a real catalog; the plan quotes it as an estimate only.
  TOKENS_PER_CHAR = 0.41
  SMOKE_TEXT = 'Консультация терапевта'.freeze

  class Error < StandardError; end

  attr_reader :model

  def initialize(model: nil, backup_dir: nil, out: $stdout)
    @model = model.presence || current_model || LlmConstants::DEFAULT_EMBEDDING_MODEL
    @backup_dir = backup_dir
    @out = out
  end

  def current_model
    Captain::Llm::EmbeddingService.configured_embedding_model.presence
  end

  # The dry run: what apply would do. Calls no model and writes nothing.
  def preview
    plan = Captain::Llm::EmbeddingSources::KEYS.index_with { |key| source_plan(key) }
    chars = plan.values.sum { |item| item[:chars] }
    {
      model: model, current_model: current_model, switches_model: current_model != model, sources: plan,
      rows: plan.values.sum { |item| item[:rows] }, chars: chars, estimated_tokens: (chars * TOKENS_PER_CHAR).round,
      requests: plan.values.sum { |item| item[:requests] }, key_configured: Llm::Config.api_key('openrouter').present?
    }
  end

  # Which model made the vectors of each table, and how many vectors have a wrong size.
  def status
    Captain::Llm::EmbeddingSources::KEYS.index_with do |key|
      table = Captain::Llm::EmbeddingSources.table_name(key)
      by_model = connection.select_rows(
        "SELECT embedding_model, COUNT(*) FROM #{table} WHERE embedding IS NOT NULL GROUP BY embedding_model ORDER BY 2 DESC"
      ).to_h { |name, count| [name.presence || 'unknown', count.to_i] }
      wrong = connection.select_value("SELECT COUNT(*) FROM #{table} WHERE embedding IS NOT NULL AND vector_dims(embedding) <> #{dimensions}")
      { rows: connection.select_value("SELECT COUNT(*) FROM #{table}").to_i, vectors_by_model: by_model, wrong_size: wrong.to_i }
    end
  end

  # Backs up, embeds and stores. Returns the manifest with the status after the switch. Raises, with nothing stored, when the model cannot
  # be reached or answers with a wrong size.
  def apply!
    raise Error, 'BACKUP_DIR is required' if @backup_dir.blank?

    rows = Captain::Llm::EmbeddingSources::KEYS.index_with { |key| Captain::Llm::EmbeddingSources.rows(key) }
    preflight!(rows)
    manifest = Captain::Llm::EmbeddingBackup.new(@backup_dir).write!(target_model: model)
    say "Backup of the old vectors written to #{@backup_dir} (#{manifest['files'].values.sum { |item| item['rows'] }} rows)."
    vectors = embed_all(rows)
    store_all!(rows, vectors)
    manifest.merge('stored' => rows.transform_values(&:size), 'status' => status)
  end

  # Puts the vectors and the setting back as they were in the backup directory.
  def restore!
    raise Error, 'BACKUP_DIR is required' if @backup_dir.blank?

    Captain::Llm::EmbeddingBackup.new(@backup_dir).restore!
  end

  private

  def connection
    ActiveRecord::Base.connection
  end

  def dimensions
    Captain::KnowledgeSettings::VECTOR_DIMENSIONS
  end

  def say(message)
    @out.puts(message)
  end

  def source_plan(key)
    rows = Captain::Llm::EmbeddingSources.rows(key)
    table = Captain::Llm::EmbeddingSources.table_name(key)
    {
      rows: rows.size, chars: rows.sum { |row| row.text.length }, accounts: rows.map(&:account_id).uniq.size,
      requests: rows.group_by(&:account_id).sum { |_, items| (items.size.to_f / Captain::Llm::EmbeddingService::BATCH_MAX_INPUTS).ceil },
      with_vector_now: connection.select_value("SELECT COUNT(*) FROM #{table} WHERE embedding IS NOT NULL").to_i
    }
  end

  # One real request before anything is written: the key works, the model exists, and it answers with exactly VECTOR_DIMENSIONS numbers.
  def preflight!(rows)
    raise Error, 'OpenRouter embeddings are not configured (CAPTAIN_OPENROUTER_API_KEY)' if Llm::Config.api_key('openrouter').blank?

    account_id = rows.values.flatten.first&.account_id
    vector = Captain::Llm::EmbeddingService.new(account_id: account_id)
                                           .get_embeddings([SMOKE_TEXT], model: model,
                                                                         input_type: Captain::Llm::EmbeddingService::SEARCH_DOCUMENT_INPUT_TYPE).first
    raise Error, "#{model} answered #{vector&.size.inspect} numbers, expected #{dimensions}" unless vector&.size == dimensions

    say "Preflight: #{model} answers with #{vector.size} numbers."
  end

  # Every text of every account in batches; nothing is stored yet.
  def embed_all(rows)
    rows.to_h do |key, items|
      vectors = {}
      items.group_by(&:account_id).each do |account_id, account_rows|
        embedder = Captain::Llm::EmbeddingService.new(account_id: account_id)
        result = embedder.get_embeddings(account_rows.map(&:text), model: model, input_type: Captain::Llm::EmbeddingSources.input_type(key))
        account_rows.zip(result).each { |row, vector| vectors[row.id] = vector }
      end
      say "Embedded #{key}: #{vectors.size} texts."
      [key, vectors]
    end
  end

  def store_all!(rows, vectors)
    ActiveRecord::Base.transaction do
      rows.each { |key, items| items.each { |row| store_row!(key, row, vectors.fetch(key).fetch(row.id)) } }
      switch_setting!
    end
    say "Stored the new vectors and switched #{Captain::Llm::EmbeddingBackup::CONFIG_NAME} to #{model}."
  end

  def store_row!(key, row, vector)
    sets = ['embedding = ?::vector', 'embedding_model = ?']
    values = ["[#{Captain::Llm::EmbeddingService.normalize(vector).map(&:to_f).join(',')}]", model]
    if Captain::Llm::EmbeddingSources::CHECKSUM_KEYS.include?(key)
      sets << 'embedding_checksum = ?'
      values << Captain::Llm::EmbeddingService.checksum(row.text)
    end
    if Captain::Llm::EmbeddingSources::EMBEDDED_AT_KEYS.include?(key)
      sets << 'embedded_at = ?'
      values << Time.current
    end
    table = Captain::Llm::EmbeddingSources.table_name(key)
    connection.exec_update(ActiveRecord::Base.sanitize_sql_array(["UPDATE #{table} SET #{sets.join(', ')} WHERE id = ?", *values, row.id]))
  end

  def switch_setting!
    setting = InstallationConfig.find_or_initialize_by(name: Captain::Llm::EmbeddingBackup::CONFIG_NAME)
    setting.value = model
    setting.locked = false
    setting.save!
  end
end
