# frozen_string_literal: true

namespace :storage do
  desc 'Offload local voice recordings to ps.kz S3 and remove local disk copies while preserving DB quota sizes'
  task :offload_local_recordings, %i[account_id dry_run] => :environment do |_t, args|
    account = args[:account_id].present? ? Account.find(args[:account_id]) : nil
    dry_run = ActiveModel::Type::Boolean.new.cast(args[:dry_run])
    result = Storage::OffloadLocalRecordingsService.new(account: account, dry_run: dry_run).perform
    puts result.to_json
  end
end
