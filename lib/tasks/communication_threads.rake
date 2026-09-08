# frozen_string_literal: true

namespace :communication_threads do
  desc 'Backfill communication threads for existing conversations. DRY_RUN=true by default; pass DRY_RUN=false to apply.'
  task backfill: :environment do
    dry_run = ENV.fetch('DRY_RUN', 'true') != 'false'
    account_id = ENV['ACCOUNT_ID'].presence
    batch_size = ENV.fetch('BATCH_SIZE', '1000').to_i

    result = CommunicationThreads::BackfillJob.perform_now(
      account_id: account_id,
      dry_run: dry_run,
      batch_size: batch_size
    )

    puts JSON.pretty_generate(result)
  end

  desc 'Repair aggregate unread counters for one account. DRY_RUN=true by default; pass DRY_RUN=false to apply.'
  task repair_unread_counts: :environment do
    account_id = ENV['ACCOUNT_ID'].presence || abort('ACCOUNT_ID is required')
    account = Account.find_by(id: account_id) || abort("Account #{account_id} was not found")
    dry_run = ActiveModel::Type::Boolean.new.cast(ENV.fetch('DRY_RUN', 'true'))
    batch_size = ENV.fetch('BATCH_SIZE', CommunicationThreads::UnreadCountRepairService::DEFAULT_BATCH_SIZE).to_i

    result = CommunicationThreads::UnreadCountRepairService.new(
      account: account,
      dry_run: dry_run,
      batch_size: batch_size
    ).perform

    puts JSON.pretty_generate(result)
  end
end
