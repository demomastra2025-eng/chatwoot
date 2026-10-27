# frozen_string_literal: true

require 'fileutils'
require 'json'

# One-off cleanup behind rake onelink:threads:delete_merge_lines: the activity lines "Объединено: звонок из канала «…»" and
# "Объединено: диалог из канала «…»" that the single open dialog rule wrote into the kept conversation each time a call or a
# channel joined the person (CommunicationThreads::SingleOpenDialogService writes nothing about a merge any more).
#
# - report: counts per account, writes nothing.
# - delete: writes a JSON backup first (every column of every line) and reads it back, then deletes the lines in one transaction;
#   a backup that fails deletes nothing. The merge itself (the resolved conversations, the thread links, the status transitions)
#   is not touched. Deleting skips the model callbacks: nothing is dispatched or broadcast.
# - restore: puts the lines of a backup file back with their ids, skipping those that exist and those of a conversation that is
#   gone. A dry run unless apply.
#
# Only activity messages whose text is one of the two lines in one of the three languages. They were written in the language of
# the account, an account in any other language got the Russian text (the default locale and the fallback of production).
# This is the only place that still has the texts: the locale keys went away with the code that used them.
class CommunicationThreads::MergeLinesCleanup
  class Refused < StandardError; end

  # The text before and after the name of the merged channel, the name being anything.
  LINES = [
    ['Объединено: звонок из канала «', '»'],
    ['Объединено: диалог из канала «', '»'],
    ['Merged: call from channel "', '"'],
    ['Merged: dialog from channel "', '"'],
    ['Біріктірілді: «', '» арнасынан қоңырау'],
    ['Біріктірілді: «', '» арнасынан диалог']
  ].freeze
  RESTORE_STATES = %i[to_restore already_present conversation_missing].freeze
  BACKUP_FORMAT = 'onelink_merge_lines_backup'
  BACKUP_VERSION = 1
  REQUIRED_COLUMNS = %w[id account_id inbox_id conversation_id created_at updated_at].freeze
  BATCH_SIZE = 500

  # The lines of every account.
  def self.scope
    patterns = LINES.map { |before, after| "#{Message.sanitize_sql_like(before)}%#{Message.sanitize_sql_like(after)}" }
    Message.unscoped.activity.where(Array.new(patterns.size, 'messages.content LIKE ?').join(' OR '), *patterns)
  end

  def initialize(out: $stdout)
    @out = out
  end

  def report
    messages = merge_lines
    print_accounts(messages)
    finish(mode: 'dry_run', messages: messages.size, accounts: messages.map(&:account_id).uniq.size)
  end

  def delete(backup_dir:)
    raise Refused, 'BACKUP_DIR is required: the directory that receives the backup JSON before anything is deleted' if backup_dir.blank?

    messages = merge_lines
    print_accounts(messages)
    backup = messages.empty? ? nil : write_backup(messages, backup_dir)
    finish(mode: 'applied', messages: messages.size, deleted: delete_lines(messages), backup: backup)
  end

  def restore(file, apply:)
    rows = read_backup(file)
    state = restore_classifier(rows)
    rows.group_by { |row| row['account_id'] }.sort.each do |account_id, lines|
      @out.puts({ account_id: account_id, **restore_counts(lines, state) }.to_json)
    end
    restored = apply ? insert_rows(rows.select { |row| state.call(row) == :to_restore }) : 0
    finish({ mode: apply ? 'restored' : 'restore_dry_run', **restore_counts(rows, state), restored: restored })
  end

  private

  def merge_lines
    self.class.scope.order(:id).to_a
  end

  def print_accounts(messages)
    messages.group_by(&:account_id).sort.each do |account_id, lines|
      times = lines.map(&:created_at)
      @out.puts({ account_id: account_id, messages: lines.size, conversations: lines.map(&:conversation_id).uniq.size,
                  first_created_at: times.min.utc.iso8601, last_created_at: times.max.utc.iso8601 }.to_json)
    end
  end

  def finish(summary)
    @out.puts('DRY RUN: nothing was written.') if %w[dry_run restore_dry_run].include?(summary[:mode])
    @out.puts(summary.to_json)
    summary
  end

  def write_backup(messages, backup_dir)
    FileUtils.mkdir_p(backup_dir)
    path = File.join(backup_dir, "merge_lines_backup_#{Time.current.utc.strftime('%Y%m%d_%H%M%S')}.json")
    document = { format: BACKUP_FORMAT, version: BACKUP_VERSION, created_at: Time.current.utc.iso8601(6), count: messages.size,
                 messages: messages.map { |message| backup_row(message) } }
    File.open(path, 'wx', 0o600, encoding: 'UTF-8') do |file|
      file.write(JSON.pretty_generate(document))
      file.fsync
    end
    raise Refused, "The backup #{path} does not match the lines, nothing was deleted" unless read_backup(path).pluck('id') == messages.map(&:id)

    path
  end

  # Every column as Active Record reads it (the enums by name); the times to the microsecond, which the JSON of Active Support
  # would cut to milliseconds.
  def backup_row(message)
    message.attributes.transform_values { |value| value.respond_to?(:iso8601) ? value.utc.iso8601(6) : value }
  end

  def read_backup(file)
    document = JSON.parse(File.read(file, encoding: 'UTF-8'))
    unless document.is_a?(Hash) && document['format'] == BACKUP_FORMAT && document['version'] == BACKUP_VERSION
      raise Refused, "#{file} is not a #{BACKUP_FORMAT} file of version #{BACKUP_VERSION}"
    end

    rows = document['messages']
    raise Refused, "#{file} is damaged: its lines do not match its count or are not activity messages" unless valid_rows?(rows, document['count'])

    rows
  rescue Errno::ENOENT, JSON::ParserError => e
    raise Refused, "#{file} cannot be read: #{e.class}"
  end

  def valid_rows?(rows, count)
    rows.is_a?(Array) && rows.size == count && rows.all? do |row|
      row.is_a?(Hash) && row['message_type'] == 'activity' && REQUIRED_COLUMNS.all? { |column| row[column].present? }
    end
  end

  def delete_lines(messages)
    deleted = 0
    Message.transaction do
      messages.each_slice(BATCH_SIZE) { |slice| deleted += self.class.scope.where(id: slice.map(&:id)).delete_all }
      if deleted != messages.size
        raise Refused, "Only #{deleted} of #{messages.size} lines matched at the delete: they changed during the run, nothing was deleted"
      end
    end
    deleted
  end

  # What a restore does with a line of the file: puts it back, finds it there already, or has no conversation to put it into.
  def restore_classifier(rows)
    present = Message.unscoped.where(id: rows.pluck('id')).pluck(:id).to_set
    alive = Conversation.where(id: rows.pluck('conversation_id')).pluck(:id).to_set
    lambda do |row|
      if present.include?(row['id']) then :already_present
      elsif alive.include?(row['conversation_id']) then :to_restore
      else :conversation_missing
      end
    end
  end

  def restore_counts(rows, state)
    { in_file: rows.size, **RESTORE_STATES.index_with(0).merge(rows.map(&state).tally) }
  end

  # insert_all on purpose: the lines come back with their ids and the times they had, and no callback, event or thread refresh runs.
  def insert_rows(rows)
    Message.transaction do
      rows.each_slice(BATCH_SIZE).sum { |slice| Message.insert_all(slice, returning: %w[id]).rows.size } # rubocop:disable Rails/SkipsModelValidations
    end
  end
end
