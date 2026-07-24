require 'rails_helper'

RSpec.describe Whatsapp::WebhookCallbackReconciliationJob do
  let(:channel) do
    create(
      :channel_whatsapp,
      provider: 'whatsapp_cloud',
      validate_provider_config: false,
      sync_templates: false,
      provider_config: {
        'api_key' => 'token',
        'phone_number_id' => 'phone-1',
        'business_account_id' => 'waba-1',
        Whatsapp::WebhookSetupService::CALLBACK_RECOVERY_KEY => {
          'state' => 'outcome_unknown',
          'waba_id' => '123456789',
          'generation' => 'recovery-1',
          'callback_url' => 'https://example.test/webhooks/whatsapp'
        }
      }
    )
  end
  let(:setup_service) { instance_double(Whatsapp::WebhookSetupService) }

  before do
    allow(Whatsapp::WebhookSetupService).to receive(:new)
      .with(channel, '123456789', nil, recovery_generation: 'recovery-1').and_return(setup_service)
  end

  it 'replays the desired callback without scheduling a duplicate recovery job' do
    expect(setup_service).to receive(:register_callback).with(schedule_recovery: false)

    described_class.perform_now(channel.id, '123456789', 'recovery-1')
  end

  it 'does nothing after another attempt has already resolved the callback' do
    config = channel.provider_config.deep_dup
    config[Whatsapp::WebhookSetupService::CALLBACK_RECOVERY_KEY]['state'] = 'resolved'
    channel.update!(provider_config: config)
    expect(Whatsapp::WebhookSetupService).not_to receive(:new)

    described_class.perform_now(channel.id, '123456789', 'recovery-1')
  end

  it 'does not mutate Meta after the queued channel starts deleting' do
    channel.inbox.update!(deleting_at: Time.current)
    expect(Whatsapp::WebhookSetupService).not_to receive(:new)

    described_class.perform_now(channel.id, '123456789', 'recovery-1')
  end

  it 'does not mutate Meta after the channel leaves the cloud provider' do
    channel.update!(provider: 'default')
    expect(Whatsapp::WebhookSetupService).not_to receive(:new)

    described_class.perform_now(channel.id, '123456789', 'recovery-1')
  end

  it 'retries a still-unknown callback outcome' do
    allow(setup_service).to receive(:register_callback)
      .with(schedule_recovery: false)
      .and_raise(Whatsapp::FacebookApiClient::WebhookCallbackOutcomeUnknownError, 'outcome unknown')

    expect do
      described_class.perform_now(channel.id, '123456789', 'recovery-1')
    end.to have_enqueued_job(described_class).with(channel.id, '123456789', 'recovery-1')
  end

  it 'drops a queued reconciliation after the channel WABA changes' do
    channel.update!(provider_config: channel.provider_config.merge('business_account_id' => 'waba-2'))
    expect(Whatsapp::WebhookSetupService).not_to receive(:new)

    described_class.perform_now(channel.id, '123456789', 'recovery-1')
  end

  it 'drops a queued reconciliation after a newer recovery generation starts' do
    config = channel.provider_config.deep_dup
    config[Whatsapp::WebhookSetupService::CALLBACK_RECOVERY_KEY]['generation'] = 'recovery-2'
    channel.update!(provider_config: config)
    expect(Whatsapp::WebhookSetupService).not_to receive(:new)

    described_class.perform_now(channel.id, '123456789', 'recovery-1')
  end
end
