# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::OpenRouterKeyHealth do
  before do
    Rails.cache.delete(described_class::CACHE_KEY)
    InstallationConfig.where(name: described_class::MANAGEMENT_API_KEY_CONFIG).delete_all
    InstallationConfig.where(name: 'CAPTAIN_OPENROUTER_API_KEY').delete_all
    allow(Llm::Config).to receive(:api_key).and_call_original
    allow(Llm::Config).to receive(:api_key).with('openrouter').and_return(nil)
    allow(Llm::Config).to receive(:api_base).and_call_original
    allow(Llm::Config).to receive(:api_base).with('openrouter').and_return('https://openrouter.ai/api/v1')
  end

  after do
    Rails.cache.delete(described_class::CACHE_KEY)
  end

  it 'records missing status when no OpenRouter key is configured' do
    metadata = described_class.refresh!

    expect(metadata).to include(
      status: 'missing',
      configured: false,
      source: 'runtime_key'
    )
    expect(described_class.metadata).to include(status: 'missing')
  end

  it 'uses the management key for current key and credits checks' do
    upsert_installation_config(described_class::MANAGEMENT_API_KEY_CONFIG, 'management-key')
    stub_request(:get, 'https://openrouter.ai/api/v1/key')
      .with(headers: { 'Authorization' => 'Bearer management-key' })
      .to_return(
        status: 200,
        body: {
          data: {
            label: 'sk-or-v1-mgmt...123',
            is_management_key: true,
            is_provisioning_key: false,
            usage: 25.5,
            limit: 100,
            limit_remaining: 74.5,
            limit_reset: 'monthly'
          }
        }.to_json
      )
    stub_request(:get, 'https://openrouter.ai/api/v1/credits')
      .with(headers: { 'Authorization' => 'Bearer management-key' })
      .to_return(status: 200, body: { data: { total_credits: 100.5, total_usage: 25.75 } }.to_json)

    metadata = described_class.refresh!

    expect(metadata).to include(status: 'valid', configured: true, source: 'management_key')
    expect(metadata[:key]).to include(
      label: 'sk-or-v1-mgmt...123',
      key_type: 'management',
      usage: BigDecimal('25.5'),
      limit: BigDecimal(100),
      limit_remaining: BigDecimal('74.5')
    )
    expect(metadata[:credits]).to include(
      status: 'available',
      total_credits: BigDecimal('100.5'),
      total_usage: BigDecimal('25.75'),
      remaining_credits: BigDecimal('74.75')
    )
    expect(metadata.to_json).not_to include('management-key')
  end

  it 'skips credits for normal runtime keys without hiding key validity' do
    allow(Llm::Config).to receive(:api_key).with('openrouter').and_return('runtime-key')
    stub_request(:get, 'https://openrouter.ai/api/v1/key')
      .with(headers: { 'Authorization' => 'Bearer runtime-key' })
      .to_return(
        status: 200,
        body: {
          data: {
            label: 'sk-or-v1-app...123',
            is_management_key: false,
            is_provisioning_key: false,
            limit_remaining: 12
          }
        }.to_json
      )

    metadata = described_class.refresh!

    expect(metadata).to include(status: 'valid', source: 'runtime_key')
    expect(metadata[:key]).to include(key_type: 'api', limit_remaining: BigDecimal(12))
    expect(metadata[:credits]).to include(status: 'management_key_required')
  end

  it 'marks a key with an exhausted spend limit as not healthy' do
    allow(Llm::Config).to receive(:api_key).with('openrouter').and_return('runtime-key')
    stub_request(:get, 'https://openrouter.ai/api/v1/key')
      .with(headers: { 'Authorization' => 'Bearer runtime-key' })
      .to_return(
        status: 200,
        body: {
          data: {
            label: 'sk-or-v1-app...123',
            is_management_key: false,
            is_provisioning_key: false,
            limit_remaining: 0
          }
        }.to_json
      )

    metadata = described_class.refresh!

    expect(metadata).to include(status: 'key_limit_exhausted')
    expect(metadata[:key]).to include(limit_remaining: BigDecimal(0))
  end

  it 'skips credits for provisioning keys because OpenRouter credits require a management key' do
    allow(Llm::Config).to receive(:api_key).with('openrouter').and_return('provisioning-key')
    stub_request(:get, 'https://openrouter.ai/api/v1/key')
      .with(headers: { 'Authorization' => 'Bearer provisioning-key' })
      .to_return(
        status: 200,
        body: {
          data: {
            label: 'sk-or-v1-prov...123',
            is_management_key: false,
            is_provisioning_key: true
          }
        }.to_json
      )

    metadata = described_class.refresh!

    expect(metadata).to include(status: 'valid', source: 'runtime_key')
    expect(metadata[:key]).to include(key_type: 'provisioning')
    expect(metadata[:credits]).to include(
      status: 'management_key_required',
      reason: 'credits endpoint requires a management key; current key type is provisioning'
    )
  end

  it 'stores sanitized invalid-key errors' do
    allow(Llm::Config).to receive(:api_key).with('openrouter').and_return('bad-key')
    stub_request(:get, 'https://openrouter.ai/api/v1/key')
      .to_return(status: 401, body: { error: { message: 'Invalid Bearer sk-or-v1-secret' } }.to_json)

    metadata = described_class.refresh!

    expect(metadata).to include(
      status: 'invalid',
      configured: true,
      source: 'runtime_key',
      openrouter_error_category: 'invalid_api_key',
      retryable: false
    )
    expect(metadata[:error]).to eq('OpenRouter key request failed: Invalid Bearer [REDACTED]')
  end
end
