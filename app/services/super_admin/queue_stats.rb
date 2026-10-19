# frozen_string_literal: true

# The figures of the background queues (Sidekiq) for the «Очереди» tab of the monitoring page: what is running, waiting,
# retried and dead, and how long each queue has been waiting. Nil when Redis cannot be read, so the page says so.
class SuperAdmin::QueueStats
  # A queue whose oldest job has waited this long (seconds) is marked
  SLOW_LATENCY = 60

  Queue = Struct.new(:name, :size, :latency, keyword_init: true) do
    def slow? = latency >= SLOW_LATENCY
  end
  Result = Struct.new(:busy, :enqueued, :scheduled, :retries, :dead, :processed, :failed, :queues, keyword_init: true) do
    def latency = queues.map(&:latency).max.to_i
  end

  def self.read
    stats = Sidekiq::Stats.new
    queues = Sidekiq::Queue.all.map { |queue| Queue.new(name: queue.name, size: queue.size, latency: queue.latency.to_f.round) }
    Result.new(
      busy: stats.workers_size, enqueued: stats.enqueued, scheduled: stats.scheduled_size, retries: stats.retry_size,
      dead: stats.dead_size, processed: stats.processed, failed: stats.failed,
      queues: queues.sort_by { |queue| [-queue.size, queue.name] }
    )
  rescue StandardError => e
    Rails.logger.warn("[SuperAdmin] Sidekiq stats unavailable: #{e.class.name}: #{e.message}")
    nil
  end
end
