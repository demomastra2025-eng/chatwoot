namespace :onelink do
  namespace :captain_settings do
    desc 'Copy the main agent settings into account settings once per account (idempotent)'
    task backfill: :environment do
      Account.find_each do |account|
        next unless Captain::AccountSettingsBackfill.backfill!(account)

        puts({ account_id: account.id, status: 'backfilled' }.to_json)
      end
    end

    desc 'Print agent IDs and names of settings that differ from the main agent, without private values'
    task conflicts: :environment do
      Account.find_each do |account|
        Captain::AccountSettingsBackfill.conflicts(account).each { |conflict| puts conflict.to_json }
      end
    end
  end
end
