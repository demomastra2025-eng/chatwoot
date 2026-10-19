# frozen_string_literal: true

# The background queues (Sidekiq): a queue whose oldest job has waited more than SLOW_QUEUE_SECONDS (danger), jobs that are
# dead (a warning) and, when the figures cannot be read at all, a warning that says so (SuperAdmin::QueueStats).
class SuperAdmin::DashboardAlerts::Queues < SuperAdmin::DashboardAlerts::Check
  # A queue that has been waiting longer than this (seconds) is behind
  SLOW_QUEUE_SECONDS = SuperAdmin::QueueStats::SLOW_LATENCY

  def alerts
    stats = SuperAdmin::QueueStats.read
    return [alert(:queues_unavailable, severity: :warning, items: [link], count: 1)] if stats.nil?

    [slow_alert(stats), dead_alert(stats)].compact
  end

  private

  def link
    { label: text('queues.link'), url: routes.super_admin_monitoring_path(tab: 'queues'), note: nil }
  end

  def slow_alert(stats)
    slow = stats.queues.select { |queue| queue.latency > SLOW_QUEUE_SECONDS }.sort_by { |queue| -queue.latency }
    return if slow.empty?

    items = slow.map do |queue|
      wait = SuperAdmin::DisplayHelper.format_wait(queue.latency)
      link.merge(label: queue.name, note: text('queues.waiting', wait: wait, jobs: queue.jobs))
    end
    alert(:queues_slow, severity: :danger, items: items, count: slow.size)
  end

  def dead_alert(stats)
    return unless stats.dead.positive?

    alert(:queues_dead, severity: :warning, items: [link], count: stats.dead)
  end
end
