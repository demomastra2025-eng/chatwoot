# Cleans the channel secrets out of the audit-log entries already stored (onelink:audits:redact_channel_secrets).
#
# The entries of an inbox written before AuditLogs::SecretFilter was in place can hold a Telegram session string, tokens,
# passwords and the runtime snapshot of a personal channel (QR login links, the dialog ids of a history import). This walks
# those entries in batches of ids and runs the same filter on each of them. A dry run (the default) only counts; `apply: true`
# writes the filtered changes back in place, in the form they were stored (a JSON object, or the same object kept as a JSON
# string). A filtered entry is left as it is on the next run, so the run can be repeated.
#
# The report says, per inbox, how many entries and which keys would be (or were) filtered. It never carries a value. An entry
# whose changes are not a JSON object (an array, null, a string that is not the JSON of an object) cannot be examined: it is
# left as it is and counted as unparsed, with its id, so the operator can look at it before and after the run.
#
#   report = AuditLogs::ChannelSecretRedaction.new(apply: false).perform
#   report.rows          # => 6
#   report.unparsed_ids  # => []
#   report.inboxes       # => { 99 => { account_id: 1, rows: 4, unparsed: 0, keys: { 'string_session' => 2, 'runtime_state' => 3 } } }
class AuditLogs::ChannelSecretRedaction
  DEFAULT_BATCH_SIZE = 500

  Report = Struct.new(:apply, :scanned, :rows, :unparsed_ids, :inboxes, keyword_init: true) do
    def unparsed
      unparsed_ids.size
    end
  end

  def initialize(apply: false, batch_size: DEFAULT_BATCH_SIZE, inbox_ids: nil)
    @apply = apply
    @batch_size = batch_size.to_i.positive? ? batch_size.to_i : DEFAULT_BATCH_SIZE
    @inbox_ids = Array(inbox_ids).compact_blank.map(&:to_i).presence
  end

  def perform
    @report = Report.new(apply: @apply, scanned: 0, rows: 0, unparsed_ids: [], inboxes: {})
    each_batch { |rows| rows.each { |row| redact(*row) } }
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
      rows = scope.where('id > ?', last_id).order(:id).limit(@batch_size).pluck(
        :id, :auditable_id, :associated_id, Arel.sql('jsonb_typeof(audited_changes) AS storage'), Arel.sql('audited_changes::text AS raw_changes')
      )
      break if rows.empty?

      Audited::Audit.transaction { yield rows }
      last_id = rows.last.first
    end
  end

  def redact(id, auditable_id, account_id, storage, raw)
    @report.scanned += 1
    changes = stored_changes(storage, raw)
    return count_unparsed(id, auditable_id, account_id) unless changes.is_a?(Hash)

    filtered = AuditLogs::SecretFilter.filter(changes)
    keys = changes.keys.reject { |key| changes[key] == filtered[key] }
    return if keys.empty?

    count(auditable_id, account_id, keys)
    write(id, storage, filtered) if @apply
  end

  # An object is stored as JSON; an entry kept as a JSON string is a string that holds the JSON of the object
  def stored_changes(storage, raw)
    value = JSON.parse(raw.to_s)
    storage == 'string' ? JSON.parse(value) : value
  rescue JSON::ParserError, TypeError
    nil
  end

  def write(id, storage, filtered)
    json = storage == 'string' ? JSON.generate(JSON.generate(filtered)) : JSON.generate(filtered)
    # rubocop:disable Rails/SkipsModelValidations
    Audited::Audit.where(id: id).update_all(['audited_changes = CAST(? AS jsonb)', json])
    # rubocop:enable Rails/SkipsModelValidations
  end

  def count(auditable_id, account_id, keys)
    @report.rows += 1
    inbox = inbox_counts(auditable_id, account_id)
    inbox[:rows] += 1
    keys.each { |key| inbox[:keys][key] += 1 }
  end

  def count_unparsed(id, auditable_id, account_id)
    @report.unparsed_ids << id
    inbox_counts(auditable_id, account_id)[:unparsed] += 1
  end

  def inbox_counts(auditable_id, account_id)
    @report.inboxes[auditable_id] ||= { account_id: account_id, rows: 0, unparsed: 0, keys: Hash.new(0) }
  end
end
