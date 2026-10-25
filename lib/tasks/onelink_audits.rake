# Release order for the stored Telegram sessions (the owner says yes before each step on PROD):
#   1. Deploy, then run the dry run and read which inboxes report the string_session key.
#   2. APPLY=1 (and DELETE_EMPTY=1 if the entries left with no changes should go rather than stay as {}).
#   3. End those Telethon sessions in Telegram (Settings > Devices) and log the inboxes in again: a session that was read from
#      the audit log before step 2 stays valid until it is ended, and this also makes the copies in the backups useless.
#   4. The old versions of the rows keep the plain text on disk until VACUUM FULL audits rewrites the table; the backups keep it.
namespace :onelink do
  namespace :audits do
    desc 'Filter the channel secrets (session strings, tokens, passwords, runtime snapshots and runtime columns) out of the stored ' \
         'inbox audit entries. Dry run unless APPLY=1; DELETE_EMPTY=1 with APPLY=1 deletes the entries left with no changes. ' \
         'Prints counts per inbox and key and the ids of the entries it could not read, never a value. [INBOX_IDS=1,2] [BATCH_SIZE=500]'
    task redact_channel_secrets: :environment do
      apply = ENV['APPLY'] == '1'
      report = AuditLogs::ChannelSecretRedaction.new(
        apply: apply,
        delete_empty: ENV['DELETE_EMPTY'] == '1',
        batch_size: ENV.fetch('BATCH_SIZE', AuditLogs::ChannelSecretRedaction::DEFAULT_BATCH_SIZE),
        inbox_ids: ENV['INBOX_IDS'].to_s.split(',')
      ).perform

      report.inboxes.sort.each do |inbox_id, counts|
        puts({ inbox_id: inbox_id, account_id: counts[:account_id], rows: counts[:rows], empty: counts[:empty],
               unparsed: counts[:unparsed], keys: counts[:keys].sort.to_h }.to_json)
      end
      # unparsed must be 0 before APPLY=1: an entry that is not a JSON object is never examined, unparsed_ids says which to look at.
      # empty: the entries left with no changes ({}), deleted: those of them deleted with DELETE_EMPTY=1
      puts({ mode: apply ? 'applied' : 'dry_run', scanned: report.scanned, rows: report.rows, empty: report.empty,
             deleted: report.deleted, inboxes: report.inboxes.size, unparsed: report.unparsed,
             unparsed_ids: report.unparsed_ids }.to_json)
    end
  end
end
