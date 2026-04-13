json.id resource.display_id
json.title resource.title
json.description resource.description
json.account_id resource.account_id
json.inbox do
  json.partial! 'api/v1/models/inbox', formats: [:json], resource: resource.inbox
end
json.sender do
  json.partial! 'api/v1/models/agent', formats: [:json], resource: resource.sender if resource.sender.present?
end
json.message resource.message
json.instructions resource.instructions
json.text_mode resource.text_mode
json.template_params resource.template_params
json.campaign_status resource.campaign_status
json.enabled resource.enabled
json.campaign_type resource.campaign_type
if resource.campaign_type == 'one_off'
  json.scheduled_at resource.scheduled_at.to_i
  json.audience resource.audience
  latest_run = resource.latest_campaign_run
  if latest_run.present?
    json.latest_run do
      json.id latest_run.id
      json.status latest_run.status
      json.provider latest_run.metadata&.[]('provider')
      json.inbox_type latest_run.metadata&.[]('inbox_type')
      json.retry_source_run_id latest_run.metadata&.[]('retry_source_run_id')
      json.retry_contacts_count latest_run.metadata&.[]('retry_contacts_count')
      json.restart_run latest_run.metadata&.[]('restart_run')
      json.resume_run latest_run.metadata&.[]('resume_run')
      json.total_count latest_run.total_count
      json.processed_count latest_run.processed_count
      json.successful_count latest_run.successful_count
      json.failed_count latest_run.failed_count
      json.skipped_count latest_run.skipped_count
      json.progress_percentage latest_run.progress_percentage
      json.duration_seconds((latest_run.completed_at && latest_run.started_at) ? (latest_run.completed_at - latest_run.started_at).round : nil)
      json.resumable_contacts_count(
        if %w[failed cancelled].include?(latest_run.status)
          [latest_run.total_count.to_i - latest_run.processed_count.to_i, 0].max
        else
          0
        end
      )
      json.started_at latest_run.started_at&.to_i
      json.completed_at latest_run.completed_at&.to_i
      json.created_at latest_run.created_at.to_i
    end
  end
end
json.trigger_rules resource.trigger_rules
json.trigger_only_during_business_hours resource.trigger_only_during_business_hours
json.created_at resource.created_at
json.updated_at resource.updated_at
