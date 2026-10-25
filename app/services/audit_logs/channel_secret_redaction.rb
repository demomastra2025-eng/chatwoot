# Cleans the channel secrets out of the audit-log entries already stored (onelink:audits:redact_channel_secrets).
#
# The entries of an inbox written before AuditLogs::SecretFilter was in place can hold a Telegram session string, tokens,
# passwords, the runtime snapshot of a personal channel (QR login links, the dialog ids of a history import) and the runtime
# columns of its channel (connection state, last error, sync clock). This walks those entries in batches of ids and runs the same
# filter on each of them as the write path, with the channel type of the inbox. A dry run (the default) only counts;
# `apply: true` writes the filtered changes back in place, in the form they were stored (a JSON object, or the same object kept
# as a JSON string). A filtered entry is left as it is on the next run, so the run can be repeated.
#
# An entry that held nothing but runtime noise is left with no changes at all ({}): the write path would never have written it.
# It is counted as empty; with `delete_empty: true` (and `apply: true`) it is deleted instead of being written back as {}.
#
# The report says, per inbox, how many entries and which keys would be (or were) filtered, and how many entries end up empty. It
# never carries a value. An entry whose changes are not a JSON object (an array, null, a string that is not the JSON of an
# object) cannot be examined: it is left as it is and counted as unparsed, with its id, so the operator can look at it before
# and after the run.
#
#   report = AuditLogs::ChannelSecretRedaction.new(apply: false).perform
#   report.rows          # => 6
#   report.empty         # => 4
#   report.unparsed_ids  # => []
#   report.inboxes       # => { 99 => { account_id: 1, rows: 4, empty: 3, unparsed: 0, keys: { 'string_session' => 2 } } }
class AuditLogs::ChannelSecretRedaction
  DEFAULT_BATCH_SIZE = 500

  Report = Struct.new(:apply, :delete_empty, :scanned, :rows, :empty, :deleted, :unparsed_ids, :inboxes, keyword_init: true) do
    def unparsed
      unparsed_ids.size
    end
  end

  def initialize(apply: false, delete_empty: false, batch_size: DEFAULT_BATCH_SIZE, inbox_ids: nil)
    @apply = apply
    @delete_empty = delete_empty
    @batch_size = batch_size.to_i.positive? ? batch_size.to_i : DEFAULT_BATCH_SIZE
    @inbox_ids = Array(inbox_ids).compact_blank.map(&:to_i).presence
  end

  def perform
    @report = Report.new(apply: @apply, delete_empty: @delete_empty, scanned: 0, rows: 0, empty: 0, deleted: 0, unparsed_ids: [],
                         inboxes: {})
    each_batch { |rows| rows.each { |row| redact(row) } }
    @report
  end

  private

  def scope
    audits = Audited::Audit.where(auditable_type: AuditLogs::SecretFilter::CHANNEL_AUDITABLE_TYPES)
    @inbox_ids ? audits.where(auditable_id: @inbox_ids) : audits
  end

  def each_batch
    last_id = 0
    loop do
      rows = scope.joins('LEFT JOIN inboxes ON inboxes.id = audits.auditable_id')
                  .where('audits.id > ?', last_id).order('audits.id').limit(@batch_size)
                  .pluck(*batch_columns)
      break if rows.empty?

      Audited::Audit.transaction { yield rows }
      last_id = rows.last.first
    end
  end

  def batch_columns
    [
      Arel.sql('audits.id'), Arel.sql('audits.auditable_id'), Arel.sql('audits.associated_id'), Arel.sql('inboxes.channel_type'),
      Arel.sql('jsonb_typeof(audits.audited_changes) AS storage'), Arel.sql('audits.audited_changes::text AS raw_changes')
    ]
  end

  # A row of #batch_columns
  def redact(row)
    id, auditable_id, account_id, channel_type, storage, raw = row
    @report.scanned += 1
    changes = stored_changes(storage, raw)
    return count_unparsed(id, auditable_id, account_id) unless changes.is_a?(Hash)

    filtered = AuditLogs::SecretFilter.filter(changes, channel_type: channel_type)
    keys = changes.keys.reject { |key| filtered.key?(key) && changes[key] == filtered[key] }
    return if keys.empty?

    count(auditable_id, account_id, keys, empty: filtered.empty?)
    store(id, storage, filtered) if @apply
  end

  # An object is stored as JSON; an entry kept as a JSON string is a string that holds the JSON of the object
  def stored_changes(storage, raw)
    value = JSON.parse(raw.to_s)
    storage == 'string' ? JSON.parse(value) : value
  rescue JSON::ParserError, TypeError
    nil
  end

  # rubocop:disable Rails/SkipsModelValidations
  def store(id, storage, filtered)
    if filtered.empty? && @delete_empty
      @report.deleted += Audited::Audit.where(id: id).delete_all
      return
    end

    json = storage == 'string' ? JSON.generate(JSON.generate(filtered)) : JSON.generate(filtered)
    Audited::Audit.where(id: id).update_all(['audited_changes = CAST(? AS jsonb)', json])
  end
  # rubocop:enable Rails/SkipsModelValidations

  def count(auditable_id, account_id, keys, empty:)
    @report.rows += 1
    @report.empty += 1 if empty
    inbox = inbox_counts(auditable_id, account_id)
    inbox[:rows] += 1
    inbox[:empty] += 1 if empty
    keys.each { |key| inbox[:keys][key] += 1 }
  end

  def count_unparsed(id, auditable_id, account_id)
    @report.unparsed_ids << id
    inbox_counts(auditable_id, account_id)[:unparsed] += 1
  end

  def inbox_counts(auditable_id, account_id)
    @report.inboxes[auditable_id] ||= { account_id: account_id, rows: 0, empty: 0, unparsed: 0, keys: Hash.new(0) }
  end
end
