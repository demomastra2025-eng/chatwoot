require 'rails_helper'

RSpec.describe Whatsapp::WebhookSubscriptionHealthCheckJob do
  it 'enqueues scoped checks only for active WhatsApp Cloud channels' do
    active = create(:channel_whatsapp, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false)
    create(:channel_whatsapp, provider: 'default', sync_templates: false, validate_provider_config: false)
    create(
      :channel_whatsapp,
      provider: 'whatsapp_cloud',
      account: create(:account, status: 'suspended'),
      sync_templates: false,
      validate_provider_config: false
    )

    expect do
      described_class.perform_now
    end.to have_enqueued_job(Whatsapp::WebhookSubscriptionHealthCheckChannelJob).with(active.id).once
  end

  it 'enqueues only one check for active channels sharing WABA credentials' do
    primary = create(:channel_whatsapp, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false)
    sibling = create(
      :channel_whatsapp,
      provider: 'whatsapp_cloud',
      account: primary.account,
      sync_templates: false,
      validate_provider_config: false
    )
    sibling.update!(
      provider_config: sibling.provider_config.merge(
        'business_account_id' => primary.provider_config['business_account_id'],
        'phone_number_id' => 'shared-waba-phone-2',
        'api_key' => primary.provider_config['api_key']
      )
    )

    expect do
      described_class.perform_now
    end.to have_enqueued_job(Whatsapp::WebhookSubscriptionHealthCheckChannelJob)
      .with(primary.id)
      .once
  end

  it 'keeps a fallback check when shared-WABA siblings have different credentials' do
    stale_primary = create(:channel_whatsapp, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false)
    working_sibling = create(
      :channel_whatsapp,
      provider: 'whatsapp_cloud',
      account: stale_primary.account,
      sync_templates: false,
      validate_provider_config: false
    )
    stale_primary.update!(provider_config: stale_primary.provider_config.merge('api_key' => 'stale-token'))
    working_sibling.update!(
      provider_config: working_sibling.provider_config.merge(
        'business_account_id' => stale_primary.provider_config['business_account_id'],
        'phone_number_id' => 'shared-waba-working-phone',
        'api_key' => 'working-token'
      )
    )

    expect do
      described_class.perform_now
    end.to have_enqueued_job(Whatsapp::WebhookSubscriptionHealthCheckChannelJob).exactly(2).times
  end
end
