# frozen_string_literal: true

# Background-only physical accounting. A daily reconciliation includes unlinked/legacy recordings;
# intervening refreshes use ingestion/compression sizes and the saved fallback measurements.
class Storage::RecordingInventory
  RECONCILE_INTERVAL = Storage::RecordingMetadata::MEASUREMENT_MAX_AGE
  BATCH_SIZE = 500

  def initialize(account:, heartbeat: nil)
    @account = account
    @heartbeat = heartbeat
    @entries = []
    @primary_rows = []
    @measurement_updates = []
  end

  def calculate
    previous = reconciliation
    @identities = previous&.fetch(:identities, {}) || {}
    reconcile! if previous.nil? || !Storage::RecordingMetadata.recent?(previous[:checked_at]) || missing_primary_sizes?
    sessions.find_each(batch_size: BATCH_SIZE) do |session|
      heartbeat
      collect_session(session)
    end
    unlinked_files = @files ? @files.values : previous.fetch(:unlinked_files)
    unlinked = unlinked_usage(unlinked_files)
    result = summarize(unlinked)
    if @files
      linked = @entries.pluck(:identity).to_set
      @reconciliation = {
        checked_at: Time.current.to_i, unlinked_files: unlinked_files.reject { |file| linked.include?(file[:identity]) },
        identities: @by_path.transform_values { |file| file[:identity] }
      }
    end
    result
  end

  # Publish only after the overview's generation check succeeds. A failed/obsolete job must not update caches.
  def publish!
    @measurement_updates.each do |attributes|
      heartbeat
      Telephony::CallSession.where(attributes[:where]).update_all(metadata: attributes[:metadata]) # rubocop:disable Rails/SkipsModelValidations
    end
    Redis::Alfred.set(cache_key, JSON.generate(@reconciliation), ex: RECONCILE_INTERVAL.to_i) if @reconciliation
  end

  private

  def sessions
    Telephony::CallSession.where(account_id: @account.id)
                         .where("NULLIF(recording_ref, '') IS NOT NULL OR metadata->'trash' IS NOT NULL " \
                                "OR metadata #> '{recording,retained_original}' IS NOT NULL")
                         .select(:id, :account_id, :inbox_id, :conversation_id, :created_at, :external_call_ref, :recording_ref, :metadata)
  end

  def missing_primary_sizes?
    sessions.where("NULLIF(recording_ref, '') IS NOT NULL AND metadata->'trash' IS NULL")
            .where("(#{Storage::RecordingMetadata.primary_size_sql(account_id: @account.id)}) IS NULL").exists?
  end

  def reconcile!
    @files = {}
    @by_path = {}
    @by_basename = Hash.new { |hash, key| hash[key] = [] }
    Storage::RecordingPaths.each_file_with_stat_for_account(@account.id) do |path, stat|
      heartbeat
      key = Storage::RecordingMetadata.local_key(path.to_s, account_id: @account.id)
      next unless key

      file = { key: key, byte_size: stat.size, identity: "#{stat.dev}:#{stat.ino}", trash: key.start_with?('trash/') }
      @files[file[:identity]] ||= file
      @by_path[key] = file
      @by_basename[path.basename.to_s] << file
    end
  end

  def collect_session(session)
    metadata = Storage::RecordingMetadata.hash(session.metadata)
    recording = Storage::RecordingMetadata.hash(metadata['recording'])
    samples = Storage::RecordingMetadata.hash(metadata.dig('storage_metrics', 'files'))
    session_entries = recording_entries(session, metadata, recording).filter_map do |entry|
      resolve_entry(entry, samples)
    end
    @entries.concat(session_entries.map { |entry| entry.merge(inbox_id: session.inbox_id) })
    primary = session_entries.find { |entry| entry[:role] == 'primary' }
    @primary_rows << [session, primary[:byte_size]] if primary && primary[:byte_size].positive?
    save_measurements(session, session_entries, primary) if @files || session_entries.any? { |entry| entry[:measured] }
  end

  def recording_entries(session, metadata, recording)
    trash = Storage::RecordingMetadata.hash(metadata['trash'])
    return trash_entries(trash) if trash.present?

    entries = []
    if session.recording_ref.present?
      entries << { ref: session.recording_ref, byte_size: Storage::RecordingMetadata.declared_primary_size(session),
                   role: 'primary', trash: false }
    end
    retained = Storage::RecordingMetadata.hash(recording['retained_original'])
    return entries if retained.blank? || retained['purged_at'].present?

    retained_trash = Storage::RecordingMetadata.hash(retained['trash'])
    entries << if retained_trash.present?
                 { ref: retained_trash['trash_path'], byte_size: Storage::RecordingMetadata.size(retained_trash['bytes']),
                   identity_ref: retained_trash['original_path'] || retained['storage_key'], role: 'retained', trash: true }
               else
                 { ref: retained['storage_key'], byte_size: Storage::RecordingMetadata.size(retained['byte_size']),
                   role: 'retained', trash: false }
               end
    entries
  end

  def trash_entries(trash)
    manifest = Array(trash['files']).select { |entry| entry.is_a?(Hash) }
    manifest = [{ 'trash_path' => trash['trash_path'], 'byte_size' => trash['bytes'] }] if manifest.empty?
    manifest.map do |entry|
      bytes = entry['byte_size'] || (trash['bytes'] if manifest.one?)
      { ref: entry['trash_path'], identity_ref: entry['original_path'] || entry['storage_key'],
        byte_size: Storage::RecordingMetadata.size(bytes), role: 'trash', trash: true }
    end
  end

  def resolve_entry(entry, samples)
    return if entry[:ref].blank?

    entry = entry.merge(declared_size: entry[:byte_size])
    key = Storage::RecordingMetadata.local_key(entry[:ref], account_id: @account.id)
    if @files
      file = key ? @by_path[key] : unique_basename(entry[:ref])
      return entry.merge(byte_size: 0, identity: "missing:#{entry[:ref]}", measured: true) unless file

      return entry.merge(file.except(:trash), measured: true)
    end
    sample = Storage::RecordingMetadata.hash(samples[entry[:ref]])
    if sample['declared_size'] == entry[:byte_size] && Storage::RecordingMetadata.recent?(sample['checked_at'])
      bytes = Storage::RecordingMetadata.size(sample['byte_size'])
      return entry.merge(byte_size: bytes, identity: sample['identity']) unless bytes.nil?
    end
    if key && !entry[:byte_size].nil?
      old_key = Storage::RecordingMetadata.local_key(entry[:identity_ref], account_id: @account.id)
      return entry.merge(identity: @identities[key] || @identities[old_key] || "path:#{key}")
    end

    # New legacy/retained references without size metadata are measured only here, in the job.
    path = if entry[:trash]
             Storage::RecordingPaths.resolve_trash(entry[:ref], account_id: @account.id)
           else
             Storage::RecordingPaths.resolve(entry[:ref], account_id: @account.id)
           end
    stat = File.stat(path) if path
    entry.merge(byte_size: stat&.size.to_i, identity: stat ? "#{stat.dev}:#{stat.ino}" : "missing:#{entry[:ref]}", measured: true)
  rescue SystemCallError
    entry.merge(byte_size: 0, identity: "missing:#{entry[:ref]}", measured: true)
  end

  def unique_basename(reference)
    return if reference.to_s.include?('/') || reference.to_s.include?('\\')

    candidates = @by_basename[reference.to_s].uniq { |file| file[:identity] }
    candidates.first if candidates.one?
  end

  def save_measurements(session, entries, primary)
    original = session.metadata.to_h
    metrics = { 'files' => entries.to_h { |entry| [entry[:ref], measurement(entry)] } }
    if session.recording_ref.present? && original['trash'].blank?
      metrics['primary'] = measurement(primary || { ref: session.recording_ref, byte_size: 0, identity: 'missing' })
      metrics['primary']['declared_size'] = Storage::RecordingMetadata.declared_primary_size(session)
    end
    replacement = original.merge('storage_metrics' => metrics)
    # Optimistic update: never overwrite a simultaneous compression, trash, restore or ingestion.
    @measurement_updates << {
      where: { id: session.id, account_id: @account.id, recording_ref: session.recording_ref, metadata: original }, metadata: replacement
    }
  end

  def measurement(entry)
    { 'ref' => entry[:ref], 'byte_size' => entry[:byte_size], 'declared_size' => entry[:declared_size],
      'identity' => entry[:identity], 'checked_at' => Time.current.to_i }
  end

  def unlinked_usage(files)
    linked = @entries.pluck(:identity).to_set
    files.reject { |file| linked.include?(file[:identity]) }.each_with_object({ active: 0, trash: 0 }) do |file, usage|
      usage[file[:trash] ? :trash : :active] += file[:byte_size]
    end
  end

  def summarize(unlinked)
    distinct = @entries.sort_by { |entry| entry[:trash] ? 1 : 0 }.uniq { |entry| entry[:identity] }
    active = distinct.reject { |entry| entry[:trash] }.sum { |entry| entry[:byte_size] } + unlinked[:active]
    trash = distinct.select { |entry| entry[:trash] }.sum { |entry| entry[:byte_size] } + unlinked[:trash]
    by_inbox = Hash.new { |hash, key| hash[key] = { bytes: 0, count: 0 } }
    distinct.each do |entry|
      next unless entry[:byte_size].positive?

      by_inbox[entry[:inbox_id]][:bytes] += entry[:byte_size]
      by_inbox[entry[:inbox_id]][:count] += 1
    end
    { active: active, trash: trash, total: active + trash, by_inbox: by_inbox, primary_rows: @primary_rows,
      reconciled_at: @files ? Time.current.to_i : reconciliation&.dig(:checked_at) || Time.current.to_i }
  end

  def heartbeat
    @heartbeat&.call
  end

  def cache_key
    "account:#{@account.id}:recording_reconciliation_v1"
  end

  def reconciliation
    raw = Redis::Alfred.get(cache_key)
    return unless raw

    data = JSON.parse(raw)
    { checked_at: data.fetch('checked_at'), identities: data.fetch('identities'),
      unlinked_files: data.fetch('unlinked_files').map(&:symbolize_keys) }
  rescue JSON::ParserError, KeyError, TypeError
    nil
  end
end
