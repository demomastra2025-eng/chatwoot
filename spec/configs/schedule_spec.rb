## we had instances where after copy pasting the schedule block,
## the dev forgets to changes the schedule key,
## this would break some of the scheduled jobs with out explicit errors
require 'rails_helper'

RSpec.context 'with valid schedule.yml' do
  let(:file) { Rails.root.join('config/schedule.yml') }

  it 'does not have duplicates' do
    schedule_keys = []
    invalid_line_starts = [' ', '#', "\n"]
    # couldn't figure out a proper solution with yaml.parse
    # so the rudementary solution is to read the file and parse it
    # check for duplicates in the array
    File.open(file).each do |f|
      f.each_line do |line|
        next if invalid_line_starts.include?(line[0])

        schedule_keys << line.split(':')[0]
      end
    end
    # ensure that no duplicates exist
    expect(schedule_keys.count).to eq(schedule_keys.uniq.count)
  end

  it 'keeps WhatsApp call cleanup on the isolated calls queue' do
    schedule = YAML.safe_load(file.read)

    expect(schedule.dig('whatsapp_call_cleanup_job', 'queue')).to eq('whatsapp_calls')
  end

  it 'dispatches MedElement provider commands from the isolated commands queue' do
    schedule = YAML.safe_load(file.read)

    expect(schedule.dig('medelement_provider_command_dispatcher_job', 'queue')).to eq('medelement_provider_commands')
  end

  it 'sweeps pending WhatsApp mutations on the scheduled jobs queue' do
    schedule = YAML.safe_load(file.read)

    expect(schedule['whatsapp_pending_message_mutation_sweep_job']).to include(
      'cron' => '*/5 * * * *',
      'class' => 'Whatsapp::PendingMessageMutationSweepJob',
      'queue' => 'scheduled_jobs',
      'active_job' => true
    )
  end

  it 'syncs Weixin gateway channels every minute' do
    schedule = YAML.safe_load(file.read)

    expect(schedule.dig('weixin_sync_channels_job', 'cron')).to eq('*/1 * * * *')
    expect(schedule.dig('weixin_sync_channels_job', 'class')).to eq('Weixin::SyncChannelsJob')
    expect(schedule.dig('weixin_sync_channels_job', 'queue')).to eq('scheduled_jobs')
  end

  it 'refreshes the shared OpenRouter model catalog on the scheduled jobs queue' do
    schedule = YAML.safe_load(file.read)

    expect(schedule.dig('refresh_openrouter_model_catalog_job', 'cron')).to eq('17 */6 * * *')
    expect(schedule.dig('refresh_openrouter_model_catalog_job', 'class')).to eq('Internal::RefreshOpenRouterModelCatalogJob')
    expect(schedule.dig('refresh_openrouter_model_catalog_job', 'queue')).to eq('scheduled_jobs')
  end

  it 'replays unpublished CRM outbox events every minute' do
    schedule = YAML.safe_load(file.read)

    expect(schedule['crm_event_replay_job']).to include(
      'cron' => '*/1 * * * *',
      'class' => 'Crm::Events::ReplayUnpublishedJob',
      'queue' => 'scheduled_jobs',
      'active_job' => true
    )
  end

  it 'audits CRM stage-visit consistency daily' do
    schedule = YAML.safe_load(file.read)

    expect(schedule['crm_stage_visit_reconciliation_job']).to include(
      'cron' => '23 3 * * *',
      'class' => 'Crm::StageVisits::ReconcileJob',
      'queue' => 'scheduled_jobs',
      'active_job' => true
    )
  end

  describe 'MedElement probe and status reconciliation' do
    let(:schedule) { YAML.safe_load(file.read) }

    def next_utc_hours(cron, from)
      time = from
      Array.new(2) do
        time = Fugit.parse_cron(cron).next_time(time).to_t
        time.utc.hour
      end
    end

    it 'probes the fast-sync endpoint at 07:00 and 19:00 Almaty time on the scheduled jobs queue' do
      expect(schedule['medelement_delta_probe_job']).to include(
        'cron' => '0 7,19 * * * Asia/Almaty',
        'class' => 'Integrations::Medelement::DeltaProbeJob',
        'queue' => 'scheduled_jobs',
        'active_job' => true
      )
      expect(next_utc_hours(schedule.dig('medelement_delta_probe_job', 'cron'), Time.utc(2026, 10, 24, 0, 0))).to eq([2, 14])
    end

    it 'reconciles stale statuses nightly at 03:00 Almaty time, queueing the per-hook runs from the scheduled jobs queue' do
      expect(schedule['medelement_stale_status_reconciliation_job']).to include(
        'cron' => '0 3 * * * Asia/Almaty',
        'class' => 'Integrations::Medelement::StaleStatusReconciliationJob',
        'queue' => 'scheduled_jobs',
        'active_job' => true
      )
      expect(next_utc_hours(schedule.dig('medelement_stale_status_reconciliation_job', 'cron'), Time.utc(2026, 10, 24, 0, 0))).to eq([22, 22])
      expect(schedule['medelement_stale_status_reconciliation_job']).not_to have_key('args')
    end

    it 'gives sidekiq-cron entries it accepts' do
      %w[medelement_delta_probe_job medelement_stale_status_reconciliation_job].each do |name|
        job = Sidekiq::Cron::Job.new(schedule.fetch(name).merge('name' => name))

        expect(job.valid?).to be(true), job.errors.inspect
      end
    end
  end

  it 'does not schedule obsolete legacy telephony binding reconciliation' do
    schedule = YAML.safe_load(file.read)

    expect(schedule).not_to have_key('telephony_legacy_agent_binding_reconciliation_job')
  end

  it 'refreshes cached OpenRouter key health before catalog refresh windows' do
    schedule = YAML.safe_load(file.read)

    expect(schedule.dig('refresh_openrouter_key_health_job', 'cron')).to eq('7 * * * *')
    expect(schedule.dig('refresh_openrouter_key_health_job', 'class')).to eq('Internal::RefreshOpenRouterKeyHealthJob')
    expect(schedule.dig('refresh_openrouter_key_health_job', 'queue')).to eq('scheduled_jobs')
  end

  it 'checks WhatsApp Cloud API token health on the scheduled jobs queue' do
    schedule = YAML.safe_load(file.read)

    expect(schedule.dig('whatsapp_token_health_check_job', 'cron')).to eq('23 */6 * * *')
    expect(schedule.dig('whatsapp_token_health_check_job', 'class')).to eq('Whatsapp::TokenHealthCheckJob')
    expect(schedule.dig('whatsapp_token_health_check_job', 'queue')).to eq('scheduled_jobs')
  end

  it 'checks and repairs WhatsApp webhook subscriptions every 15 minutes' do
    schedule = YAML.safe_load(file.read)

    expect(schedule['whatsapp_webhook_subscription_health_check_job']).to include(
      'cron' => '*/15 * * * *',
      'class' => 'Whatsapp::WebhookSubscriptionHealthCheckJob',
      'queue' => 'scheduled_jobs'
    )
  end

  it 'checks Instagram and Facebook credential health on staggered schedules' do
    schedule = YAML.safe_load(file.read)

    expect(schedule['instagram_credential_health_check_job']).to include(
      'cron' => '31 */6 * * *',
      'class' => 'Meta::InstagramCredentialHealthCheckJob',
      'queue' => 'scheduled_jobs'
    )
    expect(schedule['facebook_page_credential_health_check_job']).to include(
      'cron' => '43 */6 * * *',
      'class' => 'Meta::FacebookPageCredentialHealthCheckJob',
      'queue' => 'scheduled_jobs'
    )
  end

  it 'schedules BCC B2B auto-billing jobs on the scheduled jobs queue' do
    schedule = YAML.safe_load(file.read)

    expect(schedule['billing_generate_upcoming_invoices_job']).to include(
      'cron' => '0 5 * * *',
      'class' => 'Billing::GenerateUpcomingInvoicesJob',
      'queue' => 'scheduled_jobs',
      'active_job' => true
    )
    expect(schedule['billing_bcc_statement_sync_job']).to include(
      'cron' => '*/15 * * * *',
      'class' => 'Billing::BccStatementSyncJob',
      'queue' => 'scheduled_jobs',
      'active_job' => true
    )
    expect(schedule['billing_bcc_recurring_charge_job']).to include(
      'cron' => '15 * * * *',
      'class' => 'Billing::BccRecurringChargeJob',
      'queue' => 'scheduled_jobs',
      'active_job' => true
    )
    expect(schedule['billing_dunning_job']).to include(
      'cron' => '30 5 * * *',
      'class' => 'Billing::DunningJob',
      'queue' => 'scheduled_jobs',
      'active_job' => true
    )
  end
end
