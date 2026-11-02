require 'sidekiq/cron/job'

namespace :accounts do
  namespace :ai_usage do
    desc 'Prepare historical source identities in retry-safe batches; does not activate metering'
    task prepare: :environment do
      rollout = Accounts::PrepareAiUsageService.new.perform
      puts "prepared=#{rollout.prepared_at.present?} cursor=#{rollout.cursor} cutoff=#{rollout.cutoff_message_id}"
    end

    desc 'Verify the prepared schema and show the pending message count'
    task preflight: :environment do
      rollout = Accounts::AiUsageRollout.current
      abort 'NO-GO: pending or generated identity index is missing or invalid' unless Accounts::AiUsageRollout.indexes_ready?
      abort 'NO-GO: historical preparation incomplete' unless rollout.prepared_at && rollout.cursor >= rollout.cutoff_message_id
      job = Sidekiq::Cron::Job.find('drain_ai_usage_job')
      unless job&.enabled? && job.klass == 'Accounts::DrainAiUsageJob' && job.cron == '17 * * * * *'
        abort 'NO-GO: scheduled AI usage recovery worker is not registered with the required schedule'
      end

      puts "prepared=true active=#{rollout.activated_at.present?} pending=#{Message.where(ai_usage_pending: true).count}"
    end

    desc 'Pause counter reconciliation while continuing durable acknowledgement capture'
    task pause: :environment do
      Accounts::AiUsageRollout.current.update!(activated_at: nil)
      puts 'active=false; pending messages retained for recovery'
    end

    desc 'Activate only after old billing writers are drained and preflight passes'
    task activate: [:environment, :preflight] do
      Accounts::AiUsageRollout.current.activate!(legacy_writers_drained: ENV['AI_USAGE_LEGACY_WRITERS_DRAINED'] == '1')
      puts 'active=true; scheduled drain_ai_usage_job must be enabled on the new worker version'
    end
  end
end
