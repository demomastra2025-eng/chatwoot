# frozen_string_literal: true

require 'net/http'
require 'json'

class OwnerFinance::SystemTelemetryService
  PROMETHEUS_URL = ENV.fetch('PROMETHEUS_URL', 'http://prometheus:9090')
  GIB = (1024.0**3)
  CPU_QUERY = '100 - (avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)'
  CPU_MAX_24H_QUERY = 'max_over_time((100 - (avg(rate(node_cpu_seconds_total{mode="idle"}[1m])) * 100))[24h:1m])'
  CPU_AVG_24H_QUERY = 'avg_over_time((100 - (avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100))[24h:5m])'
  RAM_QUERY = '(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100'
  RAM_MAX_24H_QUERY = 'max_over_time(((1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100)[24h:1m])'
  DISK_ROOT_QUERY = '100 - ((node_filesystem_avail_bytes{mountpoint="/",fstype!~"tmpfs|overlay"} ' \
                    '/ node_filesystem_size_bytes{mountpoint="/",fstype!~"tmpfs|overlay"}) * 100)'
  REDIS_OPS_QUERY = 'rate(redis_commands_processed_total[5m])'

  def perform
    series_map = fetch_all_series
    {
      updated_at: Time.current.iso8601,
      cpu: build_cpu_metrics(series_map[:cpu]),
      ram: build_ram_metrics(series_map[:ram]),
      disk: build_disk_metrics(series_map[:disk_root]),
      queues: fetch_queues(series_map[:redis_ops])
    }
  rescue StandardError => e
    Rails.logger.warn("[OwnerFinance::SystemTelemetryService] #{e.class}: #{e.message}")
    { error: e.message, updated_at: Time.current.iso8601 }
  end

  private

  def fetch_all_series
    step = 900
    now = (Time.current.to_i / step) * step
    start_ts = now - 86_400
    {
      cpu: query_range(CPU_QUERY, start_ts, now, step),
      ram: query_range(RAM_QUERY, start_ts, now, step),
      disk_root: query_range(DISK_ROOT_QUERY, start_ts, now, step),
      redis_ops: query_range(REDIS_OPS_QUERY, start_ts, now, step)
    }
  end

  def build_cpu_metrics(cpu_series)
    cores = instant_scalar('count(node_cpu_seconds_total{mode="idle"})').to_i
    current = instant_scalar(CPU_QUERY)
    current = cpu_series.last&.dig(:v).to_f if current.zero? && cpu_series.any?
    max_24h = [instant_scalar(CPU_MAX_24H_QUERY), cpu_series.pluck(:v).max.to_f, current].max
    avg_24h = instant_scalar(CPU_AVG_24H_QUERY)
    avg_24h = avg_series(cpu_series) if avg_24h.zero? && cpu_series.any?
    {
      current_pct: current.round(1),
      max_24h_pct: max_24h.round(1),
      avg_24h_pct: avg_24h.round(1),
      load1: instant_scalar('node_load1').round(2),
      cores: cores.positive? ? cores : 8,
      series: cpu_series
    }
  end

  def build_ram_metrics(ram_series)
    mem_total = instant_scalar('node_memory_MemTotal_bytes')
    mem_avail = instant_scalar('node_memory_MemAvailable_bytes')
    mem_used = [mem_total - mem_avail, 0.0].max
    fallback_pct = mem_total.positive? ? (mem_used / mem_total * 100.0) : 0.0
    current = fallback_pct.positive? ? fallback_pct : (ram_series.last&.dig(:v) || 0.0)
    max_24h = [instant_scalar(RAM_MAX_24H_QUERY), ram_series.pluck(:v).max.to_f, current].max
    {
      current_pct: current.round(1),
      max_24h_pct: max_24h.round(1),
      used_gb: (mem_used / GIB).round(1),
      total_gb: (mem_total / GIB).round(1),
      avail_gb: (mem_avail / GIB).round(1),
      series: ram_series
    }
  end

  def build_disk_metrics(disk_root_series)
    disks = fetch_disks
    fallback_root = {
      mount: '/',
      used_pct: (disk_root_series.last&.dig(:v) || 0.0).round(1),
      used_gb: 0.0, total_gb: 0.0, avail_gb: 0.0
    }
    {
      root: disks['/'] || fallback_root,
      docker: disks['/var/lib/docker'],
      series: disk_root_series
    }
  end

  def avg_series(pts)
    return 0.0 if pts.empty?

    (pts.sum { |p| p[:v] } / pts.size.to_f).round(1)
  end

  def fetch_disks
    sizes = instant_vector('node_filesystem_size_bytes{fstype!~"tmpfs|overlay|vfat"}')
    avails = instant_vector('node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|vfat"}')
    avail_map = avails.each_with_object({}) { |r, h| h[r.dig('metric', 'mountpoint')] = r.dig('value', 1).to_f }
    sizes.each_with_object({}) do |row, res|
      mount = row.dig('metric', 'mountpoint')
      info = build_mount_info(mount, row.dig('value', 1).to_f, avail_map.fetch(mount, 0.0))
      res[mount] = info if info
    end
  end

  def build_mount_info(mount, total, avail)
    return nil unless total.positive? && ['/', '/var/lib/docker'].include?(mount)

    used = [total - avail, 0.0].max
    {
      mount: mount,
      used_pct: (used / total * 100.0).round(1),
      used_gb: (used / GIB).round(1),
      total_gb: (total / GIB).round(1),
      avail_gb: (avail / GIB).round(1)
    }
  end

  def fetch_queues(redis_ops_series)
    qstats = SuperAdmin::QueueStats.read
    processes = serialize_sidekiq_processes
    queue_counters(qstats).merge(
      concurrency_total: processes.sum { |p| p[:concurrency] },
      processes_count: processes.size,
      redis_ops_sec: (redis_ops_series.last&.dig(:v) || 0.0).round(1),
      top_queues: serialize_top_queues(qstats),
      capsules: processes,
      series: redis_ops_series
    )
  rescue StandardError
    { busy: 0, enqueued: 0, scheduled: 0, retries: 0, dead: 0, max_latency_sec: 0, top_queues: [], capsules: [], series: redis_ops_series }
  end

  def queue_counters(qstats)
    return { busy: 0, enqueued: 0, scheduled: 0, retries: 0, dead: 0, processed: 0, failed: 0, max_latency_sec: 0 } unless qstats

    {
      busy: qstats.busy.to_i, enqueued: qstats.enqueued.to_i, scheduled: qstats.scheduled.to_i,
      retries: qstats.retries.to_i, dead: qstats.dead.to_i, processed: qstats.processed.to_i,
      failed: qstats.failed.to_i, max_latency_sec: qstats.latency.to_i
    }
  end

  def serialize_top_queues(qstats)
    Array(qstats&.queues).first(8).map do |q|
      { name: q.name, jobs: q.jobs.to_i, latency_sec: q.latency.to_i, slow: q.slow? }
    end
  end

  def serialize_sidekiq_processes
    Sidekiq::ProcessSet.new.map do |proc|
      {
        tag: proc['tag'].presence || proc['hostname'].to_s,
        busy: proc['busy'].to_i,
        concurrency: proc['concurrency'].to_i,
        queues: Array(proc['queues']).first(3)
      }
    end
  end

  def instant_scalar(promql)
    instant_vector(promql).first&.dig('value', 1).to_f
  end

  def instant_vector(promql)
    uri = URI("#{PROMETHEUS_URL}/api/v1/query")
    uri.query = URI.encode_www_form(query: promql)
    http_get(uri).dig('data', 'result') || []
  end

  def query_range(promql, start_ts, end_ts, step)
    uri = URI("#{PROMETHEUS_URL}/api/v1/query_range")
    uri.query = URI.encode_www_form(query: promql, start: start_ts, end: end_ts, step: step)
    values = http_get(uri).dig('data', 'result', 0, 'values') || []
    values.map { |ts, val| { t: ts.to_i, v: val.to_f.round(2) } }
  end

  def http_get(uri)
    return {} if Rails.env.test? && ENV['PROMETHEUS_URL'].blank?

    Net::HTTP.start(uri.host, uri.port, open_timeout: 1.5, read_timeout: 2.0) do |http|
      res = http.request(Net::HTTP::Get.new(uri))
      res.is_a?(Net::HTTPSuccess) ? JSON.parse(res.body) : {}
    end
  rescue StandardError
    {}
  end
end
