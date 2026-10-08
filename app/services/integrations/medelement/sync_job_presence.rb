require 'sidekiq/api'

class Integrations::Medelement::SyncJobPresence
  JOB_CLASS = 'Integrations::Medelement::SyncJob'.freeze

  def present?(run)
    queued?(run) || deferred?(run) || working?(run)
  end

  def owner_known?(run)
    worker = run.worker_state
    worker['job_id'].present? && worker['process_id'].present? && worker['token'].present? && run.worker_heartbeat_at.present?
  end

  def owner_alive?(run)
    process_id = run.worker_state['process_id']
    process_id.present? && Sidekiq::ProcessSet[process_id].present?
  end

  private

  def queued?(run)
    Sidekiq::Queue.all.any? { |queue| queue.any? { |job| matches?(job.item, run) } }
  end

  def deferred?(run)
    [Sidekiq::ScheduledSet.new, Sidekiq::RetrySet.new].any? do |set|
      set.scan(JOB_CLASS).any? { |job| matches?(job.item, run) }
    end
  end

  def working?(run)
    Sidekiq::WorkSet.new.any? { |_process_id, _thread_id, work| matches?(work.job.item, run) }
  end

  def matches?(payload, run)
    active_job = Array(payload['args']).first
    active_job = {} unless active_job.is_a?(Hash)
    return false unless [payload['class'], payload['wrapped'], active_job['job_class']].include?(JOB_CLASS)

    arguments = active_job['arguments'] || payload['args']
    # Unrecognizable sync payloads cannot prove that a candidate is orphaned.
    return true unless arguments.is_a?(Array) && arguments.first.present?
    return false unless arguments.first.to_s == run.hook_id.to_s

    arguments.second.blank? || arguments.second.to_s == run.id.to_s
  end
end
