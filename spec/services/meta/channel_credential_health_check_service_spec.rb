require 'rails_helper'

RSpec.describe Meta::ChannelCredentialHealthCheckService do
  let(:channel) do
    create(:channel_instagram, access_token: 'ig-token', expires_at: 20.days.from_now, updated_at: 1.day.ago)
  end
  let(:provider_health_service) { instance_double(Meta::AuthorizationHealthCheckService) }

  before do
    allow(Meta::AuthorizationHealthCheckService).to receive(:new).with(channel).and_return(provider_health_service)
  end

  def health_result(status:, reason:, error: nil, metadata: {})
    Meta::AuthorizationHealthCheckService::Result.new(
      status: status,
      reason: reason,
      error: error,
      metadata: metadata
    )
  end

  it 'persists healthy state without clearing an unrelated reconnect prompt' do
    result = health_result(status: :healthy, reason: 'healthy', metadata: { 'expires_at' => 20.days.from_now.iso8601 })
    allow(provider_health_service).to receive(:result).and_return(result)
    allow(channel).to receive(:reauthorization_required?).and_return(true)
    allow(channel).to receive(:authorization_error_count).and_return(0)
    allow(channel).to receive(:reauthorized!)

    expect(described_class.new(channel).perform).to eq(result)
    expect(channel).not_to have_received(:reauthorized!)
    expect(channel.reload.meta_credential_health).to have_attributes(status: 'healthy', reason: 'healthy', consecutive_failures: 0)
  end

  it 'clears a provider reconnect prompt after a healthy recovery check' do
    Meta::ChannelCredentialHealth.create!(account: channel.account, channel: channel, status: 'action_required')
    result = health_result(status: :healthy, reason: 'healthy')
    allow(provider_health_service).to receive(:result).and_return(result)
    allow(channel).to receive(:reauthorization_required?).and_return(true)
    allow(channel).to receive(:authorization_error_count).and_return(0)
    allow(channel).to receive(:reauthorized!)

    described_class.new(channel).perform

    expect(channel).to have_received(:reauthorized!).once
  end

  it 'preserves an unrelated WhatsApp reconnect prompt after a healthy provider check' do
    whatsapp_channel = create(
      :channel_whatsapp,
      provider: 'whatsapp_cloud',
      sync_templates: false,
      validate_provider_config: false
    )
    result = health_result(status: :healthy, reason: 'healthy')
    whatsapp_health_service = instance_double(Meta::AuthorizationHealthCheckService, result: result)
    allow(Meta::AuthorizationHealthCheckService).to receive(:new).with(whatsapp_channel).and_return(whatsapp_health_service)
    allow(whatsapp_channel).to receive(:reauthorization_required?).and_return(true)
    allow(whatsapp_channel).to receive(:provider_authorization_reauthorization_recorded?).and_return(false)
    allow(whatsapp_channel).to receive(:reauthorized!)

    described_class.new(whatsapp_channel).perform

    expect(whatsapp_channel).not_to have_received(:reauthorized!)
  end

  it 'prompts once for a confirmed permanent provider error and stores subcode details' do
    result = health_result(
      status: :action_required,
      reason: 'provider_authorization_failed',
      error: { 'code' => 190, 'error_subcode' => 460, 'type' => 'OAuthException' }
    )
    allow(provider_health_service).to receive(:result).and_return(result)
    allow(channel).to receive(:prompt_reauthorization!)

    described_class.new(channel).perform

    expect(channel).to have_received(:prompt_reauthorization!).once
    expect(channel.reload.meta_credential_health).to have_attributes(
      status: 'action_required', provider_code: 190, provider_subcode: 460, consecutive_failures: 1
    )
  end

  it 'keeps actionable durable health and re-raises when notification delivery cannot be queued' do
    result = health_result(
      status: :action_required,
      reason: 'provider_authorization_failed',
      error: { 'code' => 190, 'error_subcode' => 460 }
    )
    allow(provider_health_service).to receive(:result).and_return(result)
    allow(channel).to receive(:prompt_reauthorization!).and_raise(StandardError, 'queue unavailable')

    expect { described_class.new(channel).perform }.to raise_error(StandardError, 'queue unavailable')
    expect(channel.reload.meta_credential_health).to have_attributes(
      status: 'action_required', provider_code: 190, provider_subcode: 460
    )
  end

  it 'records a transient failure without prompting for reconnection' do
    result = health_result(status: :transient_failure, reason: 'provider_request_failed', error: { 'code' => 2 })
    allow(provider_health_service).to receive(:result).and_return(result)
    allow(channel).to receive(:prompt_reauthorization!)

    described_class.new(channel).perform

    expect(channel).not_to have_received(:prompt_reauthorization!)
    expect(channel.reload.meta_credential_health.status).to eq('transient_failure')
  end

  it 'repairs a missing subscription before requiring user action' do
    result = health_result(status: :degraded, reason: 'subscription_missing')
    allow(provider_health_service).to receive(:result).and_return(result)
    allow(channel).to receive(:subscribe).and_return(true)
    allow(channel).to receive(:prompt_reauthorization!)

    repaired = described_class.new(channel).perform

    expect(channel).to have_received(:subscribe).with(raise_on_error: true, access_token: 'ig-token').once
    expect(channel).not_to have_received(:prompt_reauthorization!)
    expect(repaired).to be_healthy
    expect(channel.reload.meta_credential_health.reason).to eq('subscription_repaired')
  end

  it 'keeps a failed subscription repair transient instead of claiming success' do
    result = health_result(status: :degraded, reason: 'subscription_missing')
    allow(provider_health_service).to receive(:result).and_return(result)
    allow(channel).to receive(:subscribe).and_return(false)
    allow(channel).to receive(:prompt_reauthorization!)

    failed = described_class.new(channel).perform

    expect(failed).to be_transient
    expect(channel).not_to have_received(:prompt_reauthorization!)
    expect(channel.reload.meta_credential_health.status).to eq('transient_failure')
  end
end
