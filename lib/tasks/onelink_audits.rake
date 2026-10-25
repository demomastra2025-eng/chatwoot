namespace :onelink do
  namespace :audits do
    desc 'Filter the channel secrets (session strings, tokens, passwords, runtime snapshots) out of the stored inbox audit entries. ' \
         'Dry run unless APPLY=1; prints counts per inbox and key and the ids of the entries it could not read, never a value. ' \
         '[INBOX_IDS=1,2] [BATCH_SIZE=500]'
    task redact_channel_secrets: :environment do
      apply = ENV['APPLY'] == '1'
      report = AuditLogs::ChannelSecretRedaction.new(
        apply: apply,
        batch_size: ENV.fetch('BATCH_SIZE', AuditLogs::ChannelSecretRedaction::DEFAULT_BATCH_SIZE),
        inbox_ids: ENV['INBOX_IDS'].to_s.split(',')
      ).perform

      report.inboxes.sort.each do |inbox_id, counts|
        puts({ inbox_id: inbox_id, account_id: counts[:account_id], rows: counts[:rows], unparsed: counts[:unparsed],
               keys: counts[:keys].sort.to_h }.to_json)
      end
      # unparsed must be 0 before APPLY=1: an entry that is not a JSON object is never examined, unparsed_ids says which to look at
      puts({ mode: apply ? 'applied' : 'dry_run', scanned: report.scanned, rows: report.rows, inboxes: report.inboxes.size,
             unparsed: report.unparsed, unparsed_ids: report.unparsed_ids }.to_json)
    end
  end
end
