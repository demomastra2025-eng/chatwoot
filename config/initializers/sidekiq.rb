require Rails.root.join('lib/redis/config')

schedule_file = 'config/schedule.yml'
enable_sidekiq_cron = ActiveModel::Type::Boolean.new.cast(ENV.fetch('ENABLE_SIDEKIQ_CRON', true))

Sidekiq.configure_client do |config|
  config.redis = Redis::Config.app
end

# Logs whenever a job is pulled off Redis for execution.
class ChatwootDequeuedLogger
  def call(_worker, job, queue)
    payload = job['args'].first
    Sidekiq.logger.info("Dequeued #{job['wrapped']} #{payload['job_id']} from #{queue}")
    yield
  end
end

Sidekiq.configure_server do |config|
  config.redis = Redis::Config.app

  if ActiveModel::Type::Boolean.new.cast(ENV.fetch('ENABLE_SIDEKIQ_DEQUEUE_LOGGER', false))
    config.server_middleware do |chain|
      chain.add ChatwootDequeuedLogger
    end
  end

  # skip the default start stop logging
  if Rails.env.production?
    config.logger.formatter = Sidekiq::Logger::Formatters::JSON.new
    config[:skip_default_job_logging] = true
    config.logger.level = Logger.const_get(ENV.fetch('LOG_LEVEL', 'info').upcase.to_s)
  end
end

# https://github.com/ondrejbartas/sidekiq-cron
Rails.application.reloader.to_prepare do
  next unless enable_sidekiq_cron
  next unless File.exist?(schedule_file) && Sidekiq.server?

  # load_from_hash! upserts jobs from the YAML and removes any Redis-persisted
  # jobs that share the same source tag but are no longer in the file.
  # This ensures deleted schedule entries are cleaned up on deploy.
  schedule = YAML.load_file(schedule_file)

  # Cron entries removed from schedule.yml but possibly still in Redis with
  # source:'dynamic' need explicit removal.
  %w[bulk_auto_assignment_job].each { |name| Sidekiq::Cron::Job.destroy(name) }

  Sidekiq::Cron::Job.load_from_hash!(schedule, source: 'schedule')
  Integrations::Medelement::CronScheduleService.sync_all!
end
