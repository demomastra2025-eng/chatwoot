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

  it 'refreshes cached OpenRouter key health before catalog refresh windows' do
    schedule = YAML.safe_load(file.read)

    expect(schedule.dig('refresh_openrouter_key_health_job', 'cron')).to eq('7 * * * *')
    expect(schedule.dig('refresh_openrouter_key_health_job', 'class')).to eq('Internal::RefreshOpenRouterKeyHealthJob')
    expect(schedule.dig('refresh_openrouter_key_health_job', 'queue')).to eq('scheduled_jobs')
  end
end
