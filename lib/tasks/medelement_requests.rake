namespace :medelement do
  namespace :requests do
    desc 'Print hourly MedElement HTTP attempts by clinic, caller, operation and status (HOURS=24)'
    task report: :environment do
      hours = Integer(ENV.fetch('HOURS', '24'), exception: false) || 24
      puts 'hour_utc account_id hook_id caller operation status count duration_ms first_429_at_count 429_headers 429_hint pauses last_pause_ms'
      rows = Integrations::Medelement::RequestTelemetry.report(hours: hours).sort_by do |row|
        row.values_at(:hour, :account_id, :hook_id, :lane, :operation, :status)
      end
      rows.each do |row|
        puts row.values_at(:hour, :account_id, :hook_id, :lane, :operation, :status, :count, :duration_ms,
                           :first_429_at_count, :last_429_headers, :last_429_hint, :pause_count, :last_pause_ms).map(&:to_s).join(' ')
      end
    end
  end
end
