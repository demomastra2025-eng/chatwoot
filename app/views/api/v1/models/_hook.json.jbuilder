json.id resource.id
json.app_id resource.app_id
json.resource_id resource.app_id
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

if Current.account_user&.administrator?
  metadata = {}

  if resource.medelement?
    schedule_service = Integrations::Medelement::CronScheduleService.new(hook: resource)
    metadata.merge!(
      next_sync_at: schedule_service.next_sync_at&.iso8601,
      next_sync_at_display: schedule_service.next_sync_at_display,
      last_scheduled_sync_at: schedule_service.last_enqueue_at&.iso8601,
      last_scheduled_sync_at_display: schedule_service.last_enqueue_at_display
    )
  end

  if resource.macrocrm?
    metadata[:webhook_url] = resource.macrocrm_manager_changed_webhook_url
  end

  if resource.kaspi_pay?
    metadata.merge!(resource.kaspi_pay_metadata)
  end

  if metadata.present?
    json.metadata do
      metadata.each do |key, value|
        json.set! key, value
      end
    end
  end
end
