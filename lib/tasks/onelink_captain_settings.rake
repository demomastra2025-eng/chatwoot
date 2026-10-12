namespace :onelink do
  namespace :captain_settings do
    desc 'Copy the main agent settings into account settings once per account (idempotent)'
    task backfill: :environment do
      Account.find_each do |account|
        next unless Captain::AccountSettingsBackfill.backfill!(account)

        puts({ account_id: account.id, status: 'backfilled' }.to_json)
      end
    end

    desc 'Move the wishes kept in the text of an AI-mode handoff/closing message into its "how to write" instruction ' \
         '(idempotent; DRY_RUN=1 only lists the accounts; prints account IDs and message names, never the texts)'
    task move_message_guidance: :environment do
      dry_run = ENV['DRY_RUN'].present?
      Account.find_each do |account|
        moved = Captain::AccountSettingsBackfill.move_message_guidance!(account, dry_run: dry_run)
        next if moved.empty?

        puts({ account_id: account.id, status: dry_run ? 'would_move' : 'moved', messages: moved }.to_json)
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
