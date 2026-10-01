namespace :onelink do
  namespace :shared_phones do
    desc 'Dry-run report of family numbers (counts only, no personal data). [ACCOUNT_ID=]'
    task report: :environment do
      accounts = ENV['ACCOUNT_ID'].present? ? Account.where(id: ENV['ACCOUNT_ID']) : Account.order(:id)
      accounts.find_each { |account| puts Contacts::SharedPhoneReport.new(account: account).counts.to_json }
    end

    desc 'Show the shared-number switches (installation configs, default off; change them in Super Admin -> Installation configs)'
    task switches: :environment do
      puts Contacts::SharedPhoneSwitches.states.to_json
    end

    desc 'Revert a recorded number history transfer. Dry run unless APPLY=1 (needs ONELINK_SHARED_PHONE_HISTORY_TRANSFER). ' \
         'ACCOUNT_ID= CONTACT_ID=<recipient card> TRANSFER_ID= [RESTORE_PRIMARY=1]'
    task revert_transfer: :environment do
      account = Account.find(ENV.fetch('ACCOUNT_ID'))
      contact = account.contacts.find(ENV.fetch('CONTACT_ID'))
      result = Contacts::NumberHistoryTransferRevertService.new(
        contact: contact, transfer_id: ENV.fetch('TRANSFER_ID'), restore_primary: ENV['RESTORE_PRIMARY'] == '1', dry_run: ENV['APPLY'] != '1'
      ).perform
      puts({ account_id: account.id, contact_id: contact.id, transfer_id: result.entry['id'], dry_run: result.dry_run,
             contact_inboxes: result.moved_contact_inboxes, conversations: result.moved_conversations, messages: result.moved_messages }.to_json)
    rescue Contacts::NumberHistoryTransferService::Disabled
      abort({ error: 'history_transfer_disabled', switch: Contacts::SharedPhoneSwitches::HISTORY_TRANSFER, applied: false }.to_json)
    end
  end
end
