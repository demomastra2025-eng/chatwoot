# frozen_string_literal: true

# The accounts whose disk quota is filled to 80% (a warning) and to 95% (danger), the fullest first. The hourly snapshots
# (Accounts::StorageOverviewService) say how full each quota is, and they are read with one MGET per SNAPSHOT_BATCH accounts;
# an account without a quota (unlimited), without a snapshot yet or being deleted is not a problem to show.
class SuperAdmin::DashboardAlerts::Storage < SuperAdmin::DashboardAlerts::Check
  SNAPSHOT_BATCH = 1000

  def alerts
    full = percentages.select { |row| row[:percent] >= SuperAdmin::AccountUsage::WARNING_PERCENT }.sort_by { |row| -row[:percent] }
    critical, warning = full.partition { |row| row[:percent] >= SuperAdmin::AccountUsage::CRITICAL_PERCENT }
    [storage_alert(:storage_critical, :danger, critical), storage_alert(:storage_warning, :warning, warning)].compact
  end

  private

  def storage_alert(key, severity, rows)
    return if rows.empty?

    items = rows.first(SuperAdmin::DashboardAlerts::LIST_LIMIT).map { |row| account_item(row[:id], row[:name], note(row)) }
    alert(key, severity: severity, items: items, count: rows.size,
          more_url: accounts_list_url('storage_high:'), more_label: text('storage.more'))
  end

  def note(row)
    text('storage.note', percent: row[:percent].round, used: SuperAdmin::DisplayHelper.format_bytes(row[:used]),
                         total: SuperAdmin::DisplayHelper.format_bytes(row[:total]))
  end

  def percentages
    accounts = Account.where("custom_attributes->>'marked_for_deletion_at' IS NULL").pluck(:id, :name)
    accounts.each_slice(SNAPSHOT_BATCH).flat_map do |slice|
      snapshots = Accounts::StorageOverviewService.snapshots_for(slice.map(&:first))
      slice.filter_map { |id, name| row(id, name, snapshots[id]&.dig(:limits)) }
    end
  end

  def row(id, name, limits)
    return if limits.blank? || limits[:unlimited] || limits[:total_count].to_i <= 0

    used = limits[:consumed].to_i
    total = limits[:total_count].to_i
    { id: id, name: name, used: used, total: total, percent: used.to_f / total * 100 }
  end
end
