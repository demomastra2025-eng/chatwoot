namespace :onelink do
  namespace :ai_bookings do
    desc 'Read-only AI appointment report; optional hours (1..168) and account_id'
    task :report, [:hours, :account_id] => :environment do |_task, args|
      rows = Scheduling::AiBookingReport.new(
        hours: args[:hours].presence || Scheduling::AiBookingReport::DEFAULT_HOURS,
        account_id: args[:account_id]
      ).call
      rows.each { |row| puts(row.to_json) }
    end
  end
end
