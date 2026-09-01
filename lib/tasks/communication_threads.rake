# frozen_string_literal: true

namespace :communication_threads do
  desc 'Print a read-only JSON report of Contact/Thread/Conversation routing conflicts.'
  task conflict_report: :environment do
    result = CommunicationThreads::ConflictReportService.new(account_id: ENV['ACCOUNT_ID']).perform

    puts JSON.pretty_generate(result)
  end

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
end
