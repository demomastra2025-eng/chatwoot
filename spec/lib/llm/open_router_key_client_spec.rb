# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::OpenRouterKeyClient do
  it 'fetches and normalizes current OpenRouter key metadata' do
    stub = stub_request(:get, 'https://openrouter.ai/api/v1/key')
           .with(headers: { 'Authorization' => 'Bearer openrouter-key', 'Accept' => 'application/json' })
           .to_return(
             status: 200,
             body: {
               data: {
                 label: 'sk-or-v1-au7...890',
                 usage: 25.5,
                 usage_daily: 2.5,
                 usage_weekly: 7.5,
                 usage_monthly: 25.5,
                 limit: 100,
                 limit_remaining: 74.5,
                 limit_reset: 'monthly',
                 include_byok_in_limit: false,
                 byok_usage: 1.25,
                 is_free_tier: false,
                 is_management_key: true,
                 is_provisioning_key: false,
                 expires_at: '2027-12-31T23:59:59Z'
               }
             }.to_json
           )

    result = described_class.current_key(api_key: 'openrouter-key')

    expect(stub).to have_been_requested
    expect(result).to have_attributes(
      label: 'sk-or-v1-au7...890',
      usage: BigDecimal('25.5'),
      usage_daily: BigDecimal('2.5'),
      usage_weekly: BigDecimal('7.5'),
      usage_monthly: BigDecimal('25.5'),
      limit: BigDecimal(100),
      limit_remaining: BigDecimal('74.5'),
      limit_reset: 'monthly',
      include_byok_in_limit: false,
      byok_usage: BigDecimal('1.25'),
      free_tier: false,
      management_key: true,
      provisioning_key: false,
      expires_at: '2027-12-31T23:59:59Z'
    )
    expect(result.key_type).to eq('management')
    expect(result).to be_management_capable
  end

  it 'does not treat provisioning keys as credits-capable management keys' do
    stub_request(:get, 'https://openrouter.ai/api/v1/key')
      .to_return(
        status: 200,
        body: {
          data: {
            label: 'sk-or-v1-prov...890',
            is_management_key: false,
            is_provisioning_key: true
          }
        }.to_json
      )

    result = described_class.current_key(api_key: 'provisioning-key')

    expect(result.key_type).to eq('provisioning')
    expect(result).not_to be_management_capable
  end

  it 'fetches and normalizes OpenRouter credits' do
    stub = stub_request(:get, 'https://openrouter.ai/api/v1/credits')
           .with(headers: { 'Authorization' => 'Bearer management-key' })
           .to_return(
             status: 200,
             body: { data: { total_credits: 100.5, total_usage: 25.75 } }.to_json
           )

    result = described_class.credits(api_key: 'management-key')

    expect(stub).to have_been_requested
    expect(result).to have_attributes(
      total_credits: BigDecimal('100.5'),
      total_usage: BigDecimal('25.75'),
      remaining_credits: BigDecimal('74.75')
    )
  end

  it 'normalizes API bases before key health requests' do
    stub = stub_request(:get, 'https://openrouter.ai/api/v1/key')
           .to_return(status: 200, body: { data: { label: 'sk-or-v1-au7...890' } }.to_json)

    result = described_class.current_key(
      api_key: 'openrouter-key',
      api_base: 'https://openrouter.ai/api/v1/chat/completions'
    )

    expect(stub).to have_been_requested
    expect(result.label).to eq('sk-or-v1-au7...890')
  end

  it 'raises unauthorized for invalid keys' do
    stub_request(:get, 'https://openrouter.ai/api/v1/key')
      .to_return(status: 401, body: { error: { message: 'Invalid Bearer sk-or-v1-secret' } }.to_json)

    expect do
      described_class.current_key(api_key: 'bad-key')
    end.to raise_error(RubyLLM::UnauthorizedError, 'OpenRouter key request failed: Invalid Bearer [REDACTED]')
  end

  it 'raises a configuration error when the API key is missing' do
    expect do
      described_class.current_key(api_key: nil)
    end.to raise_error(RubyLLM::ConfigurationError, /OpenRouter API key is not configured for key health/)
  end
end
