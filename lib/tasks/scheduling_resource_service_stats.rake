namespace :onelink do
  namespace :scheduling do
    desc 'Rebuild the specialist-service pairs and visit lengths from the MedElement visit history (the last 180 days). ' \
         'Usage: rake "onelink:scheduling:resource_service_stats[account_id,dry_run]" ' \
         '(account_id: one account, or blank/"all" for every account with an enabled MedElement integration; ' \
         'dry_run: "true" only prints the counts, default writes). Statuses set by staff are never changed; rows are never deleted.'
    task :resource_service_stats, [:account_id, :dry_run] => :environment do |_task, args|
      dry_run = case args[:dry_run].to_s.strip.downcase
                when '', 'false' then false
                when 'true' then true
                else raise ArgumentError, 'dry_run must be true or false'
                end
      raw_id = args[:account_id].to_s.strip.downcase
      account_ids = if raw_id.blank? || raw_id == 'all'
                      Scheduling::ResourceServiceStatsJob.account_ids
                    else
                      id = Integer(raw_id, exception: false)
                      raise ArgumentError, 'account_id must be a positive number or "all"' unless id&.positive?

                      [id]
                    end

      puts "Specialist-service pairs from the visit history: #{account_ids.size} account(s), #{dry_run ? 'DRY RUN, nothing is written' : 'writing'}"
      account_ids.each do |account_id|
        result = Scheduling::ResourceServiceStatsAggregator.new(account: Account.find(account_id)).perform(dry_run: dry_run)
        # Counts only: no names, phones or codes are printed.
        puts "account #{account_id}: history pairs #{result.history_pairs}, counting #{result.counted_pairs}, " \
             "#{dry_run ? 'would create' : 'created'} #{result.created}, #{dry_run ? 'would update' : 'updated'} #{result.updated}, " \
             "#{dry_run ? 'would mark stale' : 'marked stale'} #{result.staled}, unchanged #{result.unchanged}"
      end
    end
  end
end
