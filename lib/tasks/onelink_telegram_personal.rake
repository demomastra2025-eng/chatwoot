namespace :onelink do
  namespace :telegram_personal do
    desc 'Remove the chats of the Telegram service account (777000: login codes, sign-in notices) imported into the Telegram ' \
         'personal inboxes before it was skipped. Dry run unless APPLY=1 (deletes their messages, conversations, contact inboxes ' \
         'and the contacts left with nothing else). Prints counts per inbox, never a text. [INBOX_IDS=99,225]'
    task purge_service_account_chats: :environment do
      apply = ENV['APPLY'] == '1'
      report = TelegramPersonal::ServiceAccountPurge.new(apply: apply, inbox_ids: ENV['INBOX_IDS'].to_s.split(',')).perform

      report.inboxes.sort.each { |inbox_id, counts| puts({ inbox_id: inbox_id }.merge(counts).to_json) }
      puts({ mode: apply ? 'applied' : 'dry_run', inboxes: report.inboxes.size,
             contact_inboxes: report.total(:contact_inboxes), conversations: report.total(:conversations),
             messages: report.total(:messages), contacts: report.total(:contacts) }.to_json)
    end
  end
end
