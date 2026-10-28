class SuperAdmin::DashboardAlerts::Medelement < SuperAdmin::DashboardAlerts::Check
  def alerts
    counts = current_counts
    return [] if counts.empty?

    items = alert_items(counts)
    return [] if items.empty?

    [alert(:medelement, severity: :danger, items: items)]
  end

  private

  def current_counts
    hour = Time.current.utc.strftime('%Y%m%d%H')
    rows = Integrations::Medelement::RequestTelemetry.report(hours: 1)
    rejected = rows.select { |row| row[:status] == '429' && row[:hour] == hour }
    totals = rejected.group_by { |row| credential_for(row) }
                     .transform_values { |group| group.sum { |row| row[:count] } }
    rejected.to_h { |row| [row[:hook_id].to_i, totals.fetch(credential_for(row))] }
  end

  def credential_for(row) = row[:credential_id] || row[:hook_id]

  def alert_items(counts)
    Integrations::Hook.includes(:account).where(id: counts.keys).filter_map do |hook|
      threshold = Integrations::Medelement::Configuration.new(hook: hook).rate_alert_threshold_per_hour
      count = counts.fetch(hook.id)
      account_item(hook.account_id, hook.account.name, text('medelement.note', count: count)) if count >= threshold
    end
  end
end
