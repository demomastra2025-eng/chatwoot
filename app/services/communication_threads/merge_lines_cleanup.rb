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
# Only activity messages whose text is one of the two templates in one of the three languages. They were written in the language
# of the account, an account in any other language got the Russian text (the default locale and the fallback of production).
# This is the only place that still has the texts: the locale keys went away with the code that used them.
class CommunicationThreads::MergeLinesCleanup
  class Refused < StandardError; end

  PLACEHOLDER = '%{channel}'
  TEMPLATES = [
    'Объединено: звонок из канала «%{channel}»',
    'Объединено: диалог из канала «%{channel}»',
    'Merged: call from channel "%{channel}"',
    'Merged: dialog from channel "%{channel}"',
    'Біріктірілді: «%{channel}» арнасынан қоңырау',
    'Біріктірілді: «%{channel}» арнасынан диалог'
  ].freeze
  BACKUP_FORMAT = 'onelink_merge_lines_backup'
  BACKUP_VERSION = 1
  BATCH_SIZE = 500

  # The lines of every account: activity messages with one of the templates, the channel name being anything.
  def self.scope
    patterns = TEMPLATES.map { |template| template.split(PLACEHOLDER, -1).map { |part| Message.sanitize_sql_like(part) }.join('%') }
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
    present = Message.unscoped.where(id: rows.pluck('id')).pluck(:id).to_set
    conversations = Conversation.where(id: rows.pluck('conversation_id')).pluck(:id).to_set
    todo = rows.reject { |row| present.include?(row['id']) || !conversations.include?(row['conversation_id']) }
    print_restore(rows, todo, present, conversations)
    summary = { mode: apply ? 'restored' : 'restore_dry_run', in_file: rows.size, to_restore: todo.size,
                already_present: rows.count { |row| present.include?(row['id']) },
                conversation_missing: rows.count { |row| !conversations.include?(row['conversation_id']) } }
    finish(summary.merge(restored: apply ? insert(todo) : 0))
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

  def print_restore(rows, todo, present, conversations)
    rows.group_by { |row| row['account_id'] }.sort.each do |account_id, lines|
      @out.puts({ account_id: account_id, in_file: lines.size, to_restore: (lines & todo).size,
                  already_present: lines.count { |row| present.include?(row['id']) },
                  conversation_missing: lines.count { |row| !conversations.include?(row['conversation_id']) } }.to_json)
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
    unless rows.is_a?(Array) && rows.size == document['count'] && rows.all? { |row| restorable_row?(row) }
      raise Refused, "#{file} is damaged: its lines do not match its count or are not activity messages"
    end

    rows
  rescue Errno::ENOENT, JSON::ParserError => e
    raise Refused, "#{file} cannot be read: #{e.class}"
  end

  def restorable_row?(row)
    row.is_a?(Hash) && row['message_type'] == 'activity' &&
      %w[id account_id inbox_id conversation_id created_at updated_at].all? { |key| row[key].present? }
  end

  def delete_lines(messages)
    deleted = 0
    Message.transaction do
      messages.each_slice(BATCH_SIZE) { |slice| deleted += self.class.scope.where(id: slice.map(&:id)).delete_all }
      raise Refused, "Only #{deleted} of #{messages.size} lines matched at the delete: they changed during the run, nothing was deleted" if deleted != messages.size
    end
    deleted
  end

  def insert(rows)
    Message.transaction { rows.each_slice(BATCH_SIZE).sum { |slice| Message.insert_all(slice, returning: %w[id]).rows.size } }
  end
end
