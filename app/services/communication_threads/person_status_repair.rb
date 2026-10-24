# frozen_string_literal: true

require 'csv'
require 'fileutils'

# One-off repair behind rake onelink:person_status_repair. The status tabs and counters read only the status of the
# communication thread, and the thread has one status per person: the most urgent status of its conversations (see
# Conversations::CommunicationThreadResolver::STATUS_URGENCY). Before that rule the stored status was the one of the
# conversation saved last, so a thread with an open and a snoozed channel could be stored as snoozed and a contact merge
# left the status of the base thread as it was. The old tabs hid it by also matching the statuses of the single
# conversations; the new tabs do not, so those threads must be repaired once, with the same rule as the live code.
#
# It only writes communication_threads.status (and updated_at), and only where the stored status differs from the rule. It
# never touches a conversation, a message or an event. A dry run prints the counts and writes nothing. A real run writes the
# backup CSV (thread, status before, status after) first and stops if it cannot. It can be run again at any time: a second
# run finds nothing.
class CommunicationThreads::PersonStatusRepair
  BACKUP_HEADERS = %w[account_id thread_id thread_display_id status_before status_after].freeze
  FEATURE_NAME = 'communication_threads'
  BATCH_SIZE = 1000
  # How many threads a dry run lists; the real run writes all of them into the backup CSV.
  SAMPLE_SIZE = 50

  # SQL of the status a thread must have: the most urgent status of the conversations linked to it, NULL for a thread
  # without any. It is a correlated subquery on communication_threads, so it works in a WHERE and in a SET.
  def self.expected_status_sql
    urgency = Conversations::CommunicationThreadResolver::STATUS_URGENCY
    ranks = urgency.each_with_index.map { |status, rank| "WHEN #{Conversation.statuses.fetch(status)} THEN #{rank}" }.join(' ')
    <<~SQL.squish
      (SELECT conversations.status
         FROM communication_thread_conversations thread_links
        INNER JOIN conversations
           ON conversations.id = thread_links.conversation_id AND conversations.account_id = thread_links.account_id
        WHERE thread_links.communication_thread_id = communication_threads.id
        ORDER BY CASE conversations.status #{ranks} ELSE #{urgency.size} END
        LIMIT 1)
    SQL
  end

  attr_reader :backup_path

  def initialize(account_id: nil, dry_run: true, backup_dir: nil, out: $stdout)
    @account_id = account_id.presence
    @dry_run = dry_run
    @backup_dir = backup_dir.presence || Rails.root.join('tmp').to_s
    @out = out
    @summary = { dry_run: dry_run, threads: 0, by_change: Hash.new(0), skipped_accounts: [], repaired: 0, failed: 0 }
  end

  def perform
    rows = collect_rows
    print_rows(rows)
    return finish if @dry_run

    write_backup(rows)
    apply(rows)
    finish
  end

  private

  def accounts
    @account_id ? Account.where(id: @account_id) : Account.all
  end

  # [account_id, thread_id, thread display id, status before, status after] of every thread that differs from the rule.
  def collect_rows
    rows = []
    accounts.find_each do |account|
      # The threads of an account without the feature are not used by its dashboard; the live rule never runs there either.
      if account.feature_enabled?(FEATURE_NAME)
        rows.concat(mismatched_rows(account.id))
      else
        @summary[:skipped_accounts] << account.id
      end
    end
    rows
  end

  def mismatched_rows(account_id)
    threads = CommunicationThread.where(account_id: account_id).where("communication_threads.status <> #{self.class.expected_status_sql}")
    threads.pluck(:id, :display_id, :status, Arel.sql(self.class.expected_status_sql)).map do |id, display_id, before, after|
      [account_id, id, display_id, before, CommunicationThread.statuses.key(after)]
    end
  end

  def print_rows(rows)
    rows.each { |row| @summary[:by_change]["#{row[3]} -> #{row[4]}"] += 1 }
    @summary[:threads] = rows.size
    rows.first(SAMPLE_SIZE).each do |account_id, id, display_id, before, after|
      @out.puts("account=#{account_id} thread=#{display_id} (id #{id}) #{before} -> #{after}")
    end
    @out.puts("... and #{rows.size - SAMPLE_SIZE} more") if rows.size > SAMPLE_SIZE
  end

  # Each batch is one statement that decides the status again at the moment it writes, so a thread that a message has settled
  # in the meantime is left as it is.
  def apply(rows)
    rows.each_slice(BATCH_SIZE) do |batch|
      @summary[:repaired] += repair_batch(batch.map { |row| row[1] })
    rescue StandardError => e
      @summary[:failed] += batch.size
      @out.puts("FAILED threads #{batch.first[1]}..#{batch.last[1]}: #{e.class}: #{e.message}")
    end
  end

  def repair_batch(thread_ids)
    expected = self.class.expected_status_sql
    # rubocop:disable Rails/SkipsModelValidations
    CommunicationThread.where(id: thread_ids).where("communication_threads.status <> #{expected}")
                       .update_all(["status = #{expected}, updated_at = ?", Time.current])
    # rubocop:enable Rails/SkipsModelValidations
  end

  def finish
    @summary[:backup_csv] = backup_path if backup_path
    @out.puts(@dry_run ? 'DRY RUN: nothing was written.' : "Backup of the repaired threads: #{backup_path}")
    @out.puts(@summary.to_json)
    @summary
  end

  def write_backup(rows)
    FileUtils.mkdir_p(@backup_dir)
    @backup_path = File.join(@backup_dir, "person_status_backup_#{@account_id || 'all'}_#{Time.current.strftime('%Y%m%d_%H%M%S')}.csv")
    CSV.open(@backup_path, 'w') do |csv|
      csv << BACKUP_HEADERS
      rows.each { |row| csv << row }
    end
    raise "The backup CSV #{@backup_path} is empty" unless File.size?(@backup_path)
  end
end
