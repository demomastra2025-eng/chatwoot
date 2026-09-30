require 'rails_helper'

describe Whatsapp::EmbeddedSignupWabaResolver do
  let(:api_client) { instance_double(Whatsapp::FacebookApiClient) }

  def resolve(token_data)
    allow(api_client).to receive(:debug_token).with('business_token').and_return('data' => token_data)
    described_class.new('business_token', api_client: api_client).perform
  end

  it 'returns the WABA shared through whatsapp_business_management' do
    expect(
      resolve(
        'granular_scopes' => [
          { 'scope' => 'business_management', 'target_ids' => ['999'] },
          { 'scope' => 'whatsapp_business_management', 'target_ids' => ['111'] },
          { 'scope' => 'whatsapp_business_messaging', 'target_ids' => ['111'] }
        ]
      )
    ).to eq('111')
  end

  it 'falls back to the whatsapp_business_messaging targets' do
    expect(
      resolve('granular_scopes' => [{ 'scope' => 'whatsapp_business_messaging', 'target_ids' => [222] }])
    ).to eq('222')
  end

  it 'ignores target ids that are not Meta object ids' do
    expect(
      resolve('granular_scopes' => [{ 'scope' => 'whatsapp_business_management', 'target_ids' => ['111', '../me', ''] }])
    ).to eq('111')
  end

  it 'raises waba_not_found when no WhatsApp scope names a target' do
    expect { resolve('granular_scopes' => [{ 'scope' => 'whatsapp_business_management' }]) }
      .to raise_error(described_class::ResolutionError) { |error| expect(error.error_code).to eq('waba_not_found') }
  end

  it 'raises waba_ambiguous instead of guessing between several WABAs' do
    expect { resolve('granular_scopes' => [{ 'scope' => 'whatsapp_business_management', 'target_ids' => %w[111 333] }]) }
      .to raise_error(described_class::ResolutionError) { |error| expect(error.error_code).to eq('waba_ambiguous') }
  end
end
