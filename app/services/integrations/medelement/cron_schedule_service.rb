require 'sidekiq/cron/job'

class Integrations::Medelement::CronScheduleService
  JOB_NAME_PREFIX = 'integrations_medelement_hook'.freeze
  LEGACY_DISPATCH_JOB_NAME = 'integrations_medelement_dispatch_job'.freeze
  OPERATIONAL_PHASES = %w[specialists contacts receptions].freeze
  CATALOG_PHASES = %w[setup services].freeze
  REALTIME_PHASES = %w[receptions].freeze

  def self.sync_all!
    return true unless cron_enabled?

    Sidekiq::Cron::Job.destroy(LEGACY_DISPATCH_JOB_NAME)

    hook_ids = Integrations::Hook.where(app_id: 'medelement').pluck(:id)
    Integrations::Hook.where(app_id: 'medelement').find_each do |hook|
      new(hook: hook).sync!
    end

    destroy_stale_jobs!(hook_ids)
  end

  def self.cron_enabled?
    return false if Rails.env.test?

    ActiveModel::Type::Boolean.new.cast(ENV.fetch('ENABLE_SIDEKIQ_CRON', true))
  end

  def self.destroy_stale_jobs!(hook_ids)
    # Sidekiq::Cron::Job.all returns an Array, not an Active Record relation.
    # rubocop:disable Rails/FindEach
    Sidekiq::Cron::Job.all.each do |job|
      next unless medelement_job_name?(job.name)
      next if hook_ids.include?(extract_hook_id(job.name))

      Sidekiq::Cron::Job.destroy(job.name)
    end
    # rubocop:enable Rails/FindEach
  end

  def self.extract_hook_id(job_name)
    job_name.delete_prefix("#{JOB_NAME_PREFIX}_").to_i
  end

  def self.job_name_for(hook_id)
    "#{JOB_NAME_PREFIX}_#{hook_id}"
  end

  def self.medelement_job_name?(job_name)
    job_name.to_s.start_with?("#{JOB_NAME_PREFIX}_")
  end

  def initialize(hook:)
    @hook = hook
    @configuration = Integrations::Medelement::Configuration.new(hook: hook)
  end

  def destroy!
    return true unless self.class.cron_enabled?

    job_names.each { |name| Sidekiq::Cron::Job.destroy(name) }
    Sidekiq::Cron::Job.destroy(legacy_job_name)
  end

  def jobs
    return [] unless self.class.cron_enabled?

    job_names.filter_map { |name| Sidekiq::Cron::Job.find(name) }
  end

  def last_enqueue_at
    jobs.filter_map(&:last_enqueue_time).max
  end

  def last_enqueue_at_display
    format_time(last_enqueue_at)
  end

  def next_sync_at
    return unless hook.enabled?

    schedules.filter_map { |schedule| next_time(schedule.fetch(:cron)) }.min
  rescue StandardError
    nil
  end

  def next_sync_at_display
    format_time(next_sync_at)
  end

  def sync!
    return true unless self.class.cron_enabled?

    Sidekiq::Cron::Job.destroy(legacy_job_name)
    schedules.map { |schedule| Sidekiq::Cron::Job.create(job_attributes(schedule)) }.all?
  end

  def schedule_payload
    schedules.map do |schedule|
      job = Sidekiq::Cron::Job.find(job_name(schedule.fetch(:key))) if self.class.cron_enabled?
      next_at = next_time(schedule.fetch(:cron)) if hook.enabled?
      {
        key: schedule.fetch(:key),
        phases: schedule.fetch(:phases),
        cron: schedule.fetch(:cron),
        next_sync_at: next_at&.iso8601,
        next_sync_at_display: format_time(next_at),
        last_scheduled_sync_at: job&.last_enqueue_time&.iso8601,
        last_scheduled_sync_at_display: format_time(job&.last_enqueue_time)
      }
    end
  end

  private

  attr_reader :configuration, :hook

  def format_time(time)
    return nil unless time

    time.in_time_zone(configuration.time_zone).strftime('%Y-%m-%d %H:%M %Z')
  end

  def schedules
    [
      { key: 'realtime', phases: REALTIME_PHASES, cron: configuration.receptions_sync_cron_expression },
      { key: 'operational', phases: OPERATIONAL_PHASES, cron: configuration.sync_cron_expression },
      { key: 'catalog', phases: CATALOG_PHASES, cron: configuration.catalog_sync_cron_expression }
    ]
  end

  def job_attributes(schedule)
    {
      name: job_name(schedule.fetch(:key)),
      klass: 'Integrations::Medelement::SyncJob',
      cron: schedule.fetch(:cron),
      args: [hook.id, nil, schedule.fetch(:phases)],
      active_job: true,
      queue: 'medium',
      status: hook.enabled? ? 'enabled' : 'disabled',
      description: "Medelement #{schedule.fetch(:key)} sync for account #{hook.account_id}, hook #{hook.id}"
    }
  end

  def job_names
    schedules.map { |schedule| job_name(schedule.fetch(:key)) }
  end

  def job_name(key)
    "#{self.class.job_name_for(hook.id)}_#{key}"
  end

  def legacy_job_name
    self.class.job_name_for(hook.id)
  end

  def next_time(cron)
    Fugit.do_parse_cronish(cron)&.next_time&.to_t
  end
end
