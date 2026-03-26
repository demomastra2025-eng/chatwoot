require 'sidekiq/cron/job'

class Integrations::Medelement::CronScheduleService
  JOB_NAME_PREFIX = 'integrations_medelement_hook'.freeze
  LEGACY_DISPATCH_JOB_NAME = 'integrations_medelement_dispatch_job'.freeze

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
    Sidekiq::Cron::Job.all.each do |job|
      next unless medelement_job_name?(job.name)
      next if hook_ids.include?(extract_hook_id(job.name))

      Sidekiq::Cron::Job.destroy(job.name)
    end
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

    Sidekiq::Cron::Job.destroy(job_name)
  end

  def job
    return unless self.class.cron_enabled?

    Sidekiq::Cron::Job.find(job_name)
  end

  def last_enqueue_at
    job&.last_enqueue_time
  end

  def last_enqueue_at_display
    format_time(last_enqueue_at)
  end

  def next_sync_at
    return unless hook.enabled?

    Fugit.do_parse_cronish(configuration.sync_cron_expression)&.next_time&.to_t
  rescue StandardError
    nil
  end

  def next_sync_at_display
    format_time(next_sync_at)
  end

  def sync!
    return true unless self.class.cron_enabled?

    Sidekiq::Cron::Job.create(job_attributes)
  end

  private

  attr_reader :configuration, :hook

  def format_time(time)
    return nil unless time

    time.in_time_zone(configuration.time_zone).strftime('%Y-%m-%d %H:%M %Z')
  end

  def job_attributes
    {
      name: job_name,
      klass: 'Integrations::Medelement::SyncJob',
      cron: configuration.sync_cron_expression,
      args: [hook.id],
      active_job: true,
      queue: 'medium',
      status: hook.enabled? ? 'enabled' : 'disabled',
      description: "Medelement sync for account #{hook.account_id}, hook #{hook.id}"
    }
  end

  def job_name
    self.class.job_name_for(hook.id)
  end
end
