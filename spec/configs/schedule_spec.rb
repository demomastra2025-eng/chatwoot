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
end
