# frozen_string_literal: true

# The two arguments of the tasks below: an account id or "all", and dry_run (true when it is left out).
module OnelinkThreadTaskArguments
  def self.parse(args, task_name)
    account_id = args[:account_id].to_s.strip
    abort(%(Usage: rake "onelink:#{task_name}[<account_id|all>,<true|false>]")) if account_id.blank?
    abort("Account #{account_id} was not found") unless account_id == 'all' || Account.exists?(id: account_id)

    [account_id == 'all' ? nil : account_id, dry_run(args[:dry_run])]
  end

  def self.dry_run(value)
    case value.to_s.strip.downcase.presence || 'true'
    when 'true', '1', 'yes' then true
    when 'false', '0', 'no' then false
    else abort("dry_run must be true or false, got #{value.inspect}")
    end
  end
end

namespace :onelink do
  desc 'One open dialog per person: resolve silently every open or pending conversation of a thread except the one that stays ' \
       '(latest activity, a messenger before a call). Usage: rake "onelink:one_open_dialog_per_thread[<account_id|all>,<dry_run>]". ' \
       'dry_run is true by default: it prints the counts and (thread, kept, closed) and writes nothing. dry_run=false writes the ' \
       'backup CSV into BACKUP_DIR (default tmp/) first, then resolves. Run onelink:person_status_repair after it.'
  task :one_open_dialog_per_thread, [:account_id, :dry_run] => :environment do |_task, args|
    account_id, dry_run = OnelinkThreadTaskArguments.parse(args, 'one_open_dialog_per_thread')

    CommunicationThreads::SingleOpenDialogCleanup.new(
      account_id: account_id,
      dry_run: dry_run,
      backup_dir: ENV.fetch('BACKUP_DIR', nil)
    ).perform
  end

  desc 'One person, one status: give every communication thread the most urgent status of its conversations ' \
       '(open, pending, snoozed, resolved), the rule the status tabs and counters rely on. Threads written by the old rule (the ' \
       'conversation saved last) or left by a contact merge are repaired; only communication_threads.status is written. ' \
       'Usage: rake "onelink:person_status_repair[<account_id|all>,<dry_run>]". dry_run is true by default: it prints the counts, ' \
       'the first threads and writes nothing. dry_run=false writes the backup CSV into BACKUP_DIR (default tmp/) first, then ' \
       'repairs. Run it from the new release right after the deploy (before the new web takes traffic if you can) and after ' \
       'onelink:one_open_dialog_per_thread; it can be repeated, a second run finds nothing.'
  task :person_status_repair, [:account_id, :dry_run] => :environment do |_task, args|
    account_id, dry_run = OnelinkThreadTaskArguments.parse(args, 'person_status_repair')

    CommunicationThreads::PersonStatusRepair.new(
      account_id: account_id,
      dry_run: dry_run,
      backup_dir: ENV.fetch('BACKUP_DIR', nil)
    ).perform
  end
end
