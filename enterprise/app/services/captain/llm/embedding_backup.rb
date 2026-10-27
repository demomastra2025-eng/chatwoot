require 'zlib'
require 'digest'
require 'fileutils'

# The backup of the vectors (and of the setting that names their model) that a full re-embedding replaces: one gzip JSON-lines file per
# table (the vector as text, so that a restore writes the very same numbers), and a manifest with the row counts and the checksums of
# the files. Written with the mode 0600 in a 0700 directory: the files hold the vectors of patient texts.
class Captain::Llm::EmbeddingBackup
  CONFIG_NAME = 'CAPTAIN_EMBEDDING_MODEL'.freeze
  BATCH = 500

  class Error < StandardError; end

  def initialize(dir)
    @dir = dir.to_s
  end

  # Writes every table and the manifest. target_model: the model the vectors are about to get. Returns the manifest.
  def write!(target_model:)
    FileUtils.mkdir_p(@dir, mode: 0o700)
    files = Captain::Llm::EmbeddingSources::KEYS.index_with { |key| write_table!(key) }
    setting = InstallationConfig.find_by(name: CONFIG_NAME)
    manifest = {
      'version' => 1, 'created_at' => Time.current.utc.iso8601, 'target_model' => target_model,
      'previous_setting' => { 'exists' => setting.present?, 'value' => setting&.value }, 'files' => files
    }
    File.write(File.join(@dir, 'manifest.json'), JSON.pretty_generate(manifest), perm: 0o600)
    manifest
  end

  # Puts every table and the setting back as they were when the backup was written (all in one transaction).
  def restore!
    manifest = read_manifest
    ActiveRecord::Base.transaction do
      Captain::Llm::EmbeddingSources::KEYS.each { |key| restore_table!(key, manifest) }
      restore_setting!(manifest.fetch('previous_setting'))
    end
    manifest
  end

  def read_manifest
    manifest = JSON.parse(File.read(File.join(@dir, 'manifest.json')))
    manifest.fetch('files').each do |key, info|
      path = File.join(@dir, info.fetch('file'))
      raise Error, "backup file of #{key} is missing: #{path}" unless File.exist?(path)
      raise Error, "backup file of #{key} does not match its checksum" unless Digest::SHA256.file(path).hexdigest == info.fetch('sha256')
    end
    manifest
  end

  private

  def connection
    ActiveRecord::Base.connection
  end

  def write_table!(key)
    table = Captain::Llm::EmbeddingSources.table_name(key)
    columns = Captain::Llm::EmbeddingSources.vector_columns(key)
    path = File.join(@dir, "#{key}.jsonl.gz")
    count = 0
    Zlib::GzipWriter.open(path) do |gz|
      each_batch(table, columns) do |batch|
        batch.each { |record| gz.puts(JSON.generate(record)) }
        count += batch.size
      end
    end
    File.chmod(0o600, path)
    { 'file' => File.basename(path), 'rows' => count, 'sha256' => Digest::SHA256.file(path).hexdigest }
  end

  def each_batch(table, columns)
    select = (['id'] + columns).map { |column| column == 'embedding' ? 'embedding::text AS embedding' : column }.join(', ')
    last_id = 0
    loop do
      batch = connection.select_all("SELECT #{select} FROM #{table} WHERE id > #{last_id.to_i} ORDER BY id LIMIT #{BATCH}").to_a
      break if batch.empty?

      yield batch
      last_id = batch.last['id']
    end
  end

  def restore_table!(key, manifest)
    table = Captain::Llm::EmbeddingSources.table_name(key)
    columns = Captain::Llm::EmbeddingSources.vector_columns(key)
    sets = columns.map { |column| column == 'embedding' ? 'embedding = ?::vector' : "#{column} = ?" }.join(', ')
    ids = []
    Zlib::GzipReader.open(File.join(@dir, manifest.dig('files', key, 'file'))) do |gz|
      gz.each_line do |line|
        record = JSON.parse(line)
        ids << record['id']
        update(["UPDATE #{table} SET #{sets} WHERE id = ?", *columns.map { |column| record[column] }, record['id']])
      end
    end
    clear_rows_made_after_backup!(table, columns, ids, manifest.fetch('target_model'))
  end

  # A row made after the backup has a vector of the new model only: with the old setting back it has none.
  def clear_rows_made_after_backup!(table, columns, ids, target_model)
    sql = "UPDATE #{table} SET #{columns.map { |column| "#{column} = NULL" }.join(', ')} WHERE embedding_model = ?"
    args = [target_model]
    if ids.any?
      sql += ' AND id NOT IN (?)'
      args << ids
    end
    update([sql, *args])
  end

  def restore_setting!(previous)
    setting = InstallationConfig.find_by(name: CONFIG_NAME)
    return setting&.destroy! unless previous['exists']

    setting ||= InstallationConfig.new(name: CONFIG_NAME)
    setting.value = previous['value']
    setting.locked = false
    setting.save!
  end

  def update(sql_array)
    connection.exec_update(ActiveRecord::Base.sanitize_sql_array(sql_array))
  end
end
