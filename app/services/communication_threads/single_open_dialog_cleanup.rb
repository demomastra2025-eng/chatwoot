# frozen_string_literal: true

require 'csv'
require 'fileutils'

# One-off cleanup behind rake onelink:one_open_dialog_per_thread: applies the single open dialog rule, with the same
# service the live code uses (CommunicationThreads::SingleOpenDialogService), to the threads that already have two or more
# conversations that are not resolved: two open or pending ones, an open or pending one next to a snoozed one, and also
# several snoozed ones (all_snoozed). The old person update snoozed every channel of a person, the ones resolved long ago too,
# so the timers of a person would open all of those channels together; only the one a person is reached in stays snoozed,
# with its own timer.
#
# A dry run prints the counts and, for every thread, the conversation that stays and the ones that would be resolved, and
# writes nothing. A real run writes the backup CSV (ids and statuses before the change) first and stops if it cannot.
class CommunicationThreads::SingleOpenDialogCleanup
  BACKUP_HEADERS = %w[
    account_id thread_id thread_display_id conversation_id conversation_display_id inbox_id channel_type status
    planned_action waiting_for_callback
  ].freeze
  FEATURE_NAME = 'communication_threads'

  attr_reader :backup_path

  def initialize(account_id: nil, dry_run: true, backup_dir: nil, out: $stdout)
    @account_id = account_id.presence
    @dry_run = dry_run
    @backup_dir = backup_dir.presence || Rails.root.join('tmp').to_s
    @out = out
    @summary = { dry_run: dry_run, threads: 0, conversations_to_resolve: 0, deferred_live_call: 0, skipped_accounts: [],
                 by_channels: Hash.new(0), resolved: 0, failed: 0 }
  end

  def perform
    plans = collect_plans
    print_plans(plans)
    return finish if @dry_run

    write_backup(plans)
    apply(plans)
    finish
  end

  private

  def collect_plans
    plans = []
    CommunicationThreads::SingleOpenDialogService.threads_to_consolidate(account_id: @account_id).includes(:account).find_each do |thread|
      next skip_account(thread.account_id) unless threads_enabled?(thread.account)

      plan = CommunicationThreads::SingleOpenDialogService.new(thread: thread, dry_run: true, all_snoozed: true).perform
      plans << plan if plan&.closed.present?
      @summary[:deferred_live_call] += 1 if plan&.deferred.present?
    end
    plans
  end

  # The threads of an account without the feature are not used by its dashboard; the live rule never runs there either.
  def threads_enabled?(account)
    @enabled_accounts ||= {}
    @enabled_accounts.fetch(account.id) { @enabled_accounts[account.id] = account.feature_enabled?(FEATURE_NAME) }
  end

  def skip_account(account_id)
    @summary[:skipped_accounts] |= [account_id]
  end

  def print_plans(plans)
    plans.each do |plan|
      @summary[:threads] += 1
      @summary[:conversations_to_resolve] += plan.closed.size
      @summary[:by_channels][channels(plan)] += 1
      @out.puts(describe(plan))
    end
  end

  def apply(plans)
    plans.each do |plan|
      result = CommunicationThreads::SingleOpenDialogService.new(thread: plan.thread, all_snoozed: true).perform
      @summary[:resolved] += result&.closed&.size.to_i
    rescue StandardError => e
      @summary[:failed] += 1
      @out.puts("FAILED thread=#{plan.thread.display_id} (id #{plan.thread.id}): #{e.class}: #{e.message}")
    end
  end

  def finish
    @summary[:backup_csv] = backup_path if backup_path
    @out.puts(@dry_run ? 'DRY RUN: nothing was written.' : "Backup of the affected conversations: #{backup_path}")
    @out.puts(@summary.to_json)
    @summary
  end

  def write_backup(plans)
    FileUtils.mkdir_p(@backup_dir)
    @backup_path = File.join(@backup_dir, "one_open_dialog_backup_#{@account_id || 'all'}_#{Time.current.strftime('%Y%m%d_%H%M%S')}.csv")
    CSV.open(@backup_path, 'w') do |csv|
      csv << BACKUP_HEADERS
      plans.each { |plan| backup_rows(plan).each { |row| csv << row } }
    end
    raise "The backup CSV #{@backup_path} is empty" unless File.size?(@backup_path)
  end

  def backup_rows(plan)
    ([plan.kept] + plan.closed).map do |conversation|
      [conversation.account_id, plan.thread.id, plan.thread.display_id, conversation.id, conversation.display_id, conversation.inbox_id,
       conversation.inbox.channel_type, conversation.status, conversation.equal?(plan.kept) ? 'keep' : 'resolve',
       Telephony::MissedCallCallbackTracker.waiting_for_callback?(conversation)]
    end
  end

  def channels(plan)
    ([plan.kept] + plan.closed).map { |conversation| conversation.inbox.channel_type }.sort.join(' + ')
  end

  def describe(plan)
    "account=#{plan.thread.account_id} thread=#{plan.thread.display_id} (id #{plan.thread.id}) " \
      "kept=#{conversation_label(plan.kept)} closed=[#{plan.closed.map { |conversation| conversation_label(conversation) }.join(', ')}]"
  end

  def conversation_label(conversation)
    "#{conversation.display_id} (id #{conversation.id}, inbox #{conversation.inbox_id} #{conversation.inbox.channel_type}, #{conversation.status})"
  end
end
