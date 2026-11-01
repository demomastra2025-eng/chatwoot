# frozen_string_literal: true

namespace :compliance do
  desc 'Irreversibly erase a subject Contact, write HMAC tombstones to DB + S3, and print Destruction Certificate JSON'
  task :erase_subject, %i[account_id contact_id reason] => :environment do |_t, args|
    account = Account.find(args[:account_id])
    contact = account.contacts.find(args[:contact_id])
    certificate = Compliance::SubjectErasureService.new(
      account: account,
      contact: contact,
      reason: args[:reason].presence || 'subject_request'
    ).perform!
    puts JSON.pretty_generate(certificate)
  end

  desc 'Replay ps.kz S3 tombstone ledger into PostgreSQL and purge any resurrected contacts after DB restore'
  task :replay_tombstones, %i[account_id] => :environment do |_t, args|
    scope = args[:account_id].present? ? Account.where(id: args[:account_id]) : Account.all
    scope.find_each do |account|
      summary = Compliance::TombstoneReplayService.new(account: account).perform!
      puts JSON.generate(summary)
    end
  end
end
