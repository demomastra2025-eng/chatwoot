# frozen_string_literal: true

namespace :onelink do
  desc 'One open dialog per person: resolve silently every open or pending conversation of a thread except the one that stays ' \
       '(latest activity, a messenger before a call). Usage: rake "onelink:one_open_dialog_per_thread[<account_id|all>,<dry_run>]". ' \
       'dry_run is true by default: it prints the counts and (thread, kept, closed) and writes nothing. dry_run=false writes the ' \
       'backup CSV into BACKUP_DIR (default tmp/) first, then resolves.'
  task :one_open_dialog_per_thread, [:account_id, :dry_run] => :environment do |_task, args|
    account_id = args[:account_id].to_s.strip
    abort('Usage: rake "onelink:one_open_dialog_per_thread[<account_id|all>,<true|false>]"') if account_id.blank?
    abort("Account #{account_id} was not found") unless account_id == 'all' || Account.exists?(id: account_id)

    dry_run = case args[:dry_run].to_s.strip.downcase.presence || 'true'
              when 'true', '1', 'yes' then true
              when 'false', '0', 'no' then false
              else abort("dry_run must be true or false, got #{args[:dry_run].inspect}")
              end

    CommunicationThreads::SingleOpenDialogCleanup.new(
      account_id: account_id == 'all' ? nil : account_id,
      dry_run: dry_run,
      backup_dir: ENV.fetch('BACKUP_DIR', nil)
    ).perform
  end
end
