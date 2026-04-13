# frozen_string_literal: true

class AdministratorNotifications::CaptainObservabilityMailer < AdministratorNotifications::BaseMailer
  def alert_digest(account, report:, incidents:, recipients:)
    subject = "Captain alerts for #{account.name}: #{incidents.size} active"
    action_url = "#{ENV.fetch('FRONTEND_URL', nil)}/app/accounts/#{account.id}/captain/observability"
    meta = {
      'account_name' => account.name,
      'generated_at' => Time.current.strftime('%B %d, %Y %H:%M %Z'),
      'incident_count' => incidents.size,
      'incidents' => Array(incidents).map do |incident|
        payload = incident.to_h.deep_stringify_keys
        {
          'severity' => payload['severity'],
          'source' => payload['source'],
          'name' => payload['suite_id'].presence || payload['name'],
          'message' => payload['message'],
          'failed_count' => payload['failed_count'],
          'total_count' => payload['total_count']
        }.compact
      end,
      'checks' => Array(report['checks']).map do |check|
        payload = check.to_h.deep_stringify_keys
        {
          'name' => payload['name'],
          'status' => payload['status'],
          'message' => payload['message']
        }.compact
      end
    }

    send_notification(subject, to: recipients, action_url: action_url, meta: meta)
  end
end
