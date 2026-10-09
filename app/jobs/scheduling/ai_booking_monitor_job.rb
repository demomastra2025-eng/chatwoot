class Scheduling::AiBookingMonitorJob < ApplicationJob
  queue_as :scheduled_jobs

  DEDUP_TTL = 30.minutes.to_i

  def perform
    return if ENV['AI_BOOKING_MONITOR_ENABLED'] == 'false'

    Scheduling::AiBookingReport.new(rules: Scheduling::AiBookingReport::MONITOR_RULES).call.each do |row|
      next unless row['record_type'] == 'anomaly'
      next unless Redis::Alfred.set(dedup_key(row), true, nx: true, ex: DEDUP_TTL)

      Rails.logger.warn({
        event: 'ai_booking_anomaly', account_id: row['account_id'],
        appointment_id: row['appointment_id'], command_id: row['command_id'],
        rule: row['rule'], severity: row['severity'], age_seconds: row['age_seconds']
      }.to_json)
    end
  end

  private

  def dedup_key(row)
    "AI_BOOKING_MONITOR:#{row['account_id']}:#{row['rule']}:#{row['appointment_id']}:#{row['command_id']}"
  end
end
