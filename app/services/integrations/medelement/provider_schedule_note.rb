class Integrations::Medelement::ProviderScheduleNote
  def self.for(resource:, date:)
    return if resource.custom_attributes['medelement_specialist_code'].blank?

    day = snapshot_day(resource, date)
    return unless day&.source_checked_at

    checked_at = day.source_checked_at.in_time_zone(resource.timezone).strftime('%H:%M')
    intervals = day.windows.first(8).map do |window|
      "#{format_time(window['start_minute'])}–#{format_time(window['end_minute'])}"
    end
    hours = intervals.presence&.join(', ') || 'нет рабочих окон'
    "График #{date.iso8601}: #{hours} (по данным MedElement на #{checked_at})."
  end

  def self.snapshot_day(resource, date)
    hook = Integrations::Hook.find_by(account_id: resource.account_id, app_id: 'medelement')
    return unless hook

    Integrations::Medelement::ScheduleDay.where(account_id: resource.account_id, hook_id: hook.id,
                                                resource_id: resource.id, date: date)
                                         .where(status: %w[confirmed empty_confirmed]).order(source_checked_at: :desc).first
  end
  private_class_method :snapshot_day

  def self.format_time(minute)
    minute.divmod(60).map { |part| part.to_s.rjust(2, '0') }.join(':')
  end
  private_class_method :format_time
end
