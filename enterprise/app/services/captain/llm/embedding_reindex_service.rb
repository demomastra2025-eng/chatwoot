# The full re-embedding of everything that holds vectors (the FAQ, the help center articles, the knowledge chunks and the service
# catalog, see Captain::Llm::EmbeddingSources) with ONE embedding model, and the switch of CAPTAIN_EMBEDDING_MODEL to it.
# Vectors of two models cannot be compared, so the switch is one step:
#
#   1. a real request checks the model (it answers with 1536 numbers, it is the model that was asked for, the service search has a
#      threshold calibrated for it) and the estimated cost is checked against a cap;
#   2. the old vectors are written to a backup directory (Captain::Llm::EmbeddingBackup);
#   3. every text is embedded in memory, in batches. If anything fails here nothing has been written;
#   4. all vectors and their model name are stored in ONE database transaction, together with the CAPTAIN_EMBEDDING_MODEL setting. The
#      rows are locked first, and a row whose text changed since step 3 is left for step 5;
#   5. what was added or edited while the steps above ran is embedded again until no row has a vector of another model or of another
#      text; the run fails if some rows still have one.
#
# `rake onelink:embeddings:preview` is the dry run (no model call, no write), `status` shows which model made the vectors of each table
# and fails while a row has none that is current, `apply` does the steps (CONFIRM=yes) and `restore` puts the backup back. See
# lib/tasks/onelink_embeddings.rake.
class Captain::Llm::EmbeddingReindexService
  # The plan quotes the tokens as an estimate only.
  TOKENS_PER_CHAR = Captain::Llm::EmbeddingService::TOKENS_PER_CHAR
  # The most tokens one apply may embed (about 0.75 USD at 0.15 USD per million tokens). The whole platform today is about 0.4 million
  # tokens; a plan above the cap is refused unless MAX_TOKENS is raised on purpose.
  MAX_ESTIMATED_TOKENS = 5_000_000
  # How many times the rows that changed meanwhile are embedded again after the switch.
  CONVERGE_PASSES = 3
  SMOKE_TEXT = 'Консультация терапевта'.freeze

  class Error < StandardError; end

  attr_reader :model

  def initialize(model: nil, backup_dir: nil, out: $stdout, max_tokens: MAX_ESTIMATED_TOKENS)
    @model = model.presence || current_model || LlmConstants::DEFAULT_EMBEDDING_MODEL
    @backup_dir = backup_dir
    @out = out
    @max_tokens = max_tokens.to_i
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
      rows: plan.values.sum { |item| item[:rows] }, chars: chars, estimated_tokens: estimated_tokens(chars),
      max_tokens: @max_tokens, calibrated: Scheduling::ServiceIndex.calibrated?(model),
      requests: plan.values.sum { |item| item[:requests] }, key_configured: Llm::Config.api_key('openrouter').present?
    }
  end

  # Which model made the vectors of each table, how many vectors have a wrong size, and how many rows have no current vector of the
  # model in force (`stale`: no vector, a vector of another model, or of another text).
  def status
    in_force = Captain::Llm::EmbeddingService.embedding_model
    Captain::Llm::EmbeddingSources::KEYS.index_with do |key|
      table = Captain::Llm::EmbeddingSources.table_name(key)
      by_model = connection.select_rows(
        "SELECT embedding_model, COUNT(*) FROM #{table} WHERE embedding IS NOT NULL GROUP BY embedding_model ORDER BY 2 DESC"
      ).to_h { |name, count| [name.presence || 'unknown', count.to_i] }
      wrong = connection.select_value("SELECT COUNT(*) FROM #{table} WHERE embedding IS NOT NULL AND vector_dims(embedding) <> #{dimensions}")
      {
        rows: connection.select_value("SELECT COUNT(*) FROM #{table}").to_i, vectors_by_model: by_model, wrong_size: wrong.to_i,
        stale: Captain::Llm::EmbeddingSources.stale_rows(key, in_force).size
      }
    end
  end

  # True when every vector has the right size and every row has a current vector of the model in force.
  def consistent?(status = self.status)
    status.values.all? { |item| item[:wrong_size].zero? && item[:stale].zero? }
  end

  # Backs up, embeds and stores. Returns the manifest with the status after the switch. Raises, with nothing stored, when the model cannot
  # be reached, answers with a wrong size, or costs more than the cap; raises after the switch when rows are left without a current vector.
  def apply!
    raise Error, 'BACKUP_DIR is required' if @backup_dir.blank?

    rows = Captain::Llm::EmbeddingSources::KEYS.index_with { |key| Captain::Llm::EmbeddingSources.rows(key) }
    guard!(rows)
    preflight!(rows)
    manifest = Captain::Llm::EmbeddingBackup.new(@backup_dir).write!(target_model: model)
    say "Backup of the old vectors written to #{@backup_dir} (#{manifest['files'].values.sum { |item| item['rows'] }} rows)."
    vectors = embed_all(rows)
    store_all!(rows, vectors)
    converge!
    manifest.merge('stored' => rows.transform_values(&:size), 'status' => status)
  end

  # Embeds again the rows that have no current vector of the model in force: what the code before this release wrote after the switch
  # (its vectors have no model name), and what was added since. No backup and no switch. Returns how many rows it found.
  def refresh!
    unless Scheduling::ServiceIndex.calibrated?(model)
      raise Error, "#{model} has no service_min_score in config/llm.yml: the service search cannot work with it until it is calibrated"
    end
    raise Error, 'OpenRouter embeddings are not configured (CAPTAIN_OPENROUTER_API_KEY)' if Llm::Config.api_key('openrouter').blank?

    found = Captain::Llm::EmbeddingSources::KEYS.sum { |key| Captain::Llm::EmbeddingSources.stale_rows(key, model).size }
    converge!
    found
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

  def estimated_tokens(chars)
    (chars * TOKENS_PER_CHAR).round
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

  # Refusals that need no model call: a model whose service search has no calibrated threshold would leave the catalog unsearchable
  # (see Scheduling::ServiceIndex.min_score), and a plan above the cap is a mistake until proven otherwise.
  def guard!(rows)
    unless Scheduling::ServiceIndex.calibrated?(model)
      raise Error, "#{model} has no service_min_score in config/llm.yml: the service search cannot work with it until it is calibrated"
    end

    tokens = estimated_tokens(rows.values.flatten.sum { |row| row.text.length })
    raise Error, "The plan is about #{tokens} tokens, above the cap of #{@max_tokens} (MAX_TOKENS=... raises it)" if tokens > @max_tokens
  end

  # One real request before anything is written: the key works, the model exists, it is the model that was asked for (the request
  # checks that) and it answers with exactly VECTOR_DIMENSIONS numbers.
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
    skipped = {}
    ActiveRecord::Base.transaction do
      skipped = store_rows!(rows, vectors)
      switch_setting!
    end
    say "Stored the new vectors and switched #{Captain::Llm::EmbeddingBackup::CONFIG_NAME} to #{model}."
    say "Left for the next pass, changed meanwhile: #{skipped.map { |key, count| "#{key} #{count}" }.join(', ')}." if skipped.any?
  end

  # Locks the rows, reads them again and stores the vector of every row that still has the text that was embedded. Returns how many rows
  # of each table were left out because their text changed.
  def store_rows!(rows, vectors)
    rows.each_with_object({}) do |(key, items), skipped|
      Captain::Llm::EmbeddingSources.lock_rows!(key, items.map(&:id))
      current = Captain::Llm::EmbeddingSources.rows(key).index_by(&:id)
      changed = items.reject { |row| current[row.id]&.text == row.text }
      (items - changed).each { |row| store_row!(key, row, vectors.fetch(key).fetch(row.id)) }
      skipped[key] = changed.size if changed.any?
    end
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

  # Rows added or edited while the steps above ran (and rows whose own job wrote a vector of the old model just before the switch)
  # are embedded again, in passes, until no row has a vector of another model or of another text. In production a few rows at most.
  def converge!
    CONVERGE_PASSES.times do
      pending = Captain::Llm::EmbeddingSources::KEYS.index_with { |key| Captain::Llm::EmbeddingSources.stale_rows(key, model) }
      pending = pending.reject { |_, items| items.empty? }
      return if pending.empty?

      say "Embedding again, changed meanwhile: #{pending.map { |key, items| "#{key} #{items.size}" }.join(', ')}."
      ActiveRecord::Base.transaction { store_rows!(pending, embed_all(pending)) }
    end
    left = Captain::Llm::EmbeddingSources::KEYS.sum { |key| Captain::Llm::EmbeddingSources.stale_rows(key, model).size }
    raise Error, "#{left} rows still have no current vector of #{model} after #{CONVERGE_PASSES} passes: run apply again" if left.positive?
  end
end
