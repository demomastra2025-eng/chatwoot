# frozen_string_literal: true

namespace :owner_finance do
  desc 'Idempotently migrate Owner Finance data from Supabase into local OneLink PostgreSQL'
  task import_from_supabase: :environment do
    stats = OwnerFinance::SupabaseMigrationImporter.new.perform
    puts "[owner_finance:import_from_supabase] DONE: #{stats.to_json}"
  end

  desc 'Run Owner Finance deadline reminder sweep ([7, 3, 2, 1, 0] days)'
  task sweep_reminders: :environment do
    result = OwnerFinance::DeadlineReminderService.new.perform
    puts "[owner_finance:sweep_reminders] DONE: #{result.to_json}"
  end
end
