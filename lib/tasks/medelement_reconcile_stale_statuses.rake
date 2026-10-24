namespace :medelement do
  desc 'Re-read MedElement appointments that are still scheduled/confirmed a day after their start and apply the provider ' \
       'status. Usage: rake "medelement:reconcile_stale_statuses[account_id,days,dry_run,max_per_run]" ' \
       '(days: a number or "all", default 30; dry_run: true by default, "false" writes; max_per_run: no cap by default)'
  task :reconcile_stale_statuses, [:account_id, :days, :dry_run, :max_per_run] => :environment do |_task, args|
    account_id = Integer(args[:account_id], exception: false)
    raise ArgumentError, 'A positive account ID is required' unless account_id&.positive?

    days = case args[:days].to_s.strip.downcase
           when '' then Integrations::Medelement::StaleStatusReconciler::DEFAULT_DAYS
           when 'all', '0' then :all
           else Integer(args[:days], exception: false)
           end
    raise ArgumentError, 'days must be a positive number or "all"' unless days == :all || days&.positive?

    days = nil if days == :all

    dry_run = case args[:dry_run].to_s.strip.downcase
              when '', 'true' then true
              when 'false' then false
              else raise ArgumentError, 'dry_run must be true or false'
              end
    max_per_run = args[:max_per_run].present? ? Integer(args[:max_per_run], exception: false) : nil
    raise ArgumentError, 'max_per_run must be a positive number' if args[:max_per_run].present? && !max_per_run&.positive?

    hook = Integrations::Hook.find_by!(account_id: account_id, app_id: 'medelement')
    puts "MedElement stale statuses: account #{account_id}, hook #{hook.id}, #{days ? "last #{days} days" : 'whole history'}, " \
         "#{dry_run ? 'DRY RUN, nothing is written' : 'APPLYING'}"
    rules = AutomationRule.where(account_id: account_id, active: true, event_name: %w[appointment_updated appointment_completed appointment_cancelled])
    puts "Active automation rules that react to an appointment status change: #{rules.count}" unless dry_run

    report = Integrations::Medelement::StaleStatusReconciler.new(
      hook: hook, days: days, dry_run: dry_run, max_per_run: max_per_run
    ).perform
    # Counts and appointment ids only: no names, phones, IINs or reception codes are printed.
    puts 'old status -> status at MedElement: appointments'
    puts report.summary_lines
    puts "examined #{report.examined}: #{dry_run ? 'would change' : 'changed'} #{report.changed}, unchanged #{report.unchanged}, " \
         "not found #{report.not_found}, out of scope #{report.out_of_scope}, skipped #{report.skipped}, errors #{report.errors}; " \
         "#{report.remaining} candidates not examined"
    next unless report.aborted

    puts "STOPPED: #{report.aborted} (not_eligible: hook disabled or receptions sync off; already_running; sync_busy; " \
         'provider_errors; lock_lost). Run the same command again to continue: appointments already closed are not selected again.'
    exit 1
  end
end
