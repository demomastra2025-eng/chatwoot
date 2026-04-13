namespace :chatwoot do
  namespace :contacts do
    desc 'Backfill contact channel profiles for existing contact inboxes'
    task backfill_channel_profiles: :environment do
      scope = ContactInbox.all
      scope = scope.joins(:inbox).where(inboxes: { account_id: ENV['ACCOUNT_ID'] }) if ENV['ACCOUNT_ID'].present?

      result = Contacts::ChannelProfileBackfillService.new(
        scope: scope,
        batch_size: ENV.fetch('BATCH_SIZE', 500).to_i,
        force: ActiveModel::Type::Boolean.new.cast(ENV.fetch('FORCE', nil))
      ).perform

      puts "Processed: #{result.processed_count}"
      puts "Created: #{result.created_count}"
      puts "Updated: #{result.updated_count}"
      puts "Skipped: #{result.skipped_count}"
      puts "Failed: #{result.failed_count}"
    end
  end
end
