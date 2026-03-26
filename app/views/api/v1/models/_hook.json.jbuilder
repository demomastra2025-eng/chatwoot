json.id resource.id
json.app_id resource.app_id
json.status resource.enabled?
json.inbox resource.inbox&.slice(:id, :name)
json.account_id resource.account_id
json.hook_type resource.hook_type

if Current.account_user&.administrator?
  settings_payload = resource.settings

  if resource.medelement?
    configuration = Integrations::Medelement::Configuration.new(hook: resource)
    settings_payload = settings_payload.merge(
      'sync_interval_hours' => configuration.sync_interval_hours,
      'sync_time_of_day' => configuration.sync_time_of_day
    )
  end

  json.settings settings_payload
end
json.reference_id resource.reference_id if Current.account_user&.administrator?

if Current.account_user&.administrator? && resource.medelement?
  schedule_service = Integrations::Medelement::CronScheduleService.new(hook: resource)

  json.metadata do
    json.next_sync_at schedule_service.next_sync_at&.iso8601
    json.next_sync_at_display schedule_service.next_sync_at_display
    json.last_scheduled_sync_at schedule_service.last_enqueue_at&.iso8601
    json.last_scheduled_sync_at_display schedule_service.last_enqueue_at_display
  end
end
