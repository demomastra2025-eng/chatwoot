require 'rails_helper'

RSpec.describe Whatsapp::ReauthorizationIdentityResolver do
  let(:access_token) { 'fresh-token' }
  let(:account_id) { 74 }
  let(:inbox_id) { 229 }
  let(:channel_id) { 31 }
  let(:physical_phone) { '+1 (202) 555-0100' }
  let(:old_identity) do
    {
      'business_account_id' => '10001',
      'phone_number_id' => '20001',
      'business_id' => '30001',
      'source' => 'embedded_signup',
      'embedded_signup_flow' => 'standard'
    }
  end
  let(:api_client) { instance_double(Whatsapp::FacebookApiClient) }
  let(:waba_phone_pages) do
    {
      '10002' => [
        {
          'id' => '20002',
          'display_phone_number' => '+1 202 555-0100',
          'verified_name' => 'Retained business',
          'is_on_biz_app' => true,
          'platform_type' => 'CLOUD_API'
        }
      ]
    }
  end
  let(:granular_scopes) do
    [
      { 'scope' => 'whatsapp_business_management', 'target_ids' => ['10002'] },
      { 'scope' => 'whatsapp_business_messaging', 'target_ids' => ['10002'] }
    ]
  end

  before do
    allow(GlobalConfigService).to receive(:load).with('WHATSAPP_APP_ID', '').and_return('meta-app')
    allow(api_client).to receive(:debug_token).with(access_token).and_return(
      'data' => {
        'app_id' => 'meta-app',
        'is_valid' => true,
        'scopes' => %w[whatsapp_business_management whatsapp_business_messaging],
        'granular_scopes' => granular_scopes
      }
    )
    allow(api_client).to receive(:fetch_phone_numbers) do |waba_id, **options|
      pages = waba_phone_pages.fetch(waba_id)
      pages.is_a?(Hash) ? pages.fetch(options[:after]) : { 'data' => pages }
    end
    allow(api_client).to receive(:fetch_waba_info).and_return(
      'owner_business_info' => { 'id' => '30001' }
    )
  end

  def resolve(requested_waba_id: nil, requested_phone_number_id: nil, requested_business_id: nil,
              identity: old_identity, flow: 'standard')
    described_class.new(
      access_token: access_token,
      account_id: account_id,
      inbox_id: inbox_id,
      channel_id: channel_id,
      old_identity: identity,
      phone_number: physical_phone,
      signup_type: flow,
      requested_waba_id: requested_waba_id,
      requested_phone_number_id: requested_phone_number_id,
      requested_business_id: requested_business_id,
      api_client: api_client
    ).perform
  end

  it 'proves an exact physical phone and the same owner business before accepting changed ids' do
    resolution = resolve

    expect(resolution).to be_identity_changed
    expect(resolution.target_identity).to include(
      'business_account_id' => '10002',
      'phone_number_id' => '20002',
      'business_id' => '30001'
    )
    expect(api_client).to have_received(:fetch_waba_info)
      .with('10002', fields: ['owner_business_info'])
  end

  it 'requires owner-business proof for a changed identity' do
    allow(api_client).to receive(:fetch_waba_info).and_return(
      'owner_business_info' => { 'id' => 'another-business' }
    )

    expect { resolve }
      .to raise_error(described_class::ResolutionError) { |error| expect(error.error_code).to eq('business_identity_mismatch') }
  end

  it 'rejects ambiguous matching phones instead of taking the first WABA' do
    waba_phone_pages['10003'] = waba_phone_pages.fetch('10002')
    granular_scopes.each { |scope| scope['target_ids'] << '10003' }

    expect { resolve }
      .to raise_error(described_class::ResolutionError) { |error| expect(error.error_code).to eq('asset_ambiguous') }
    expect(api_client).not_to have_received(:fetch_waba_info)
  end

  it 'honors an explicit WABA choice and never substitutes another matching WABA' do
    waba_phone_pages['10003'] = waba_phone_pages.fetch('10002')
    granular_scopes.each { |scope| scope['target_ids'] << '10003' }

    expect(resolve(requested_waba_id: '10003').target_identity['business_account_id']).to eq('10003')
    expect(api_client).to have_received(:fetch_phone_numbers).with('10003', hash_including(:after, :fields))
    expect(api_client).not_to have_received(:fetch_phone_numbers).with('10002', anything)
  end

  it 'rejects an explicit phone id that does not match the retained physical number' do
    expect { resolve(requested_waba_id: '10002', requested_phone_number_id: '29999') }
      .to raise_error(described_class::ResolutionError) do |error|
        expect(error.error_code).to eq('phone_asset_selection_mismatch')
      end
  end

  it 'fails closed when required granular permissions grant different WABAs, even if bare scopes are present' do
    granular_scopes[1]['target_ids'] = ['10003']

    expect { resolve }
      .to raise_error(described_class::ResolutionError) do |error|
        expect(error.error_code).to eq('required_asset_grants_missing')
      end
    expect(api_client).not_to have_received(:fetch_phone_numbers)
  end

  it 'uses the scoped target list when another required permission is genuinely global' do
    granular_scopes.pop
    expect(resolve.target_identity['business_account_id']).to eq('10002')
  end

  it 'does not treat an empty granular target row as a global permission' do
    granular_scopes[0]['target_ids'] = []

    expect { resolve }
      .to raise_error(described_class::ResolutionError) do |error|
        expect(error.error_code).to eq('grant_targets_incomplete')
      end
    expect(api_client).not_to have_received(:fetch_phone_numbers)
  end

  it 'does not require owner-business migration proof when the stored identity remains exact' do
    waba_phone_pages['10001'] = [
      { 'id' => '20001', 'display_phone_number' => '+1 202 555-0100' }
    ]
    granular_scopes.each { |scope| scope['target_ids'] = ['10001'] }
    identity_without_business = old_identity.merge('business_id' => nil)

    resolution = resolve(identity: identity_without_business)

    expect(resolution.identity_changed?).to be(false)
    expect(api_client).not_to have_received(:fetch_waba_info)
  end

  it 'requires the exact coexistence-capable phone when recovering a coexistence identity' do
    waba_phone_pages['10002'][0]['is_on_biz_app'] = false
    coexistence_identity = old_identity.merge('embedded_signup_flow' => 'coexistence')

    expect { resolve(identity: coexistence_identity, flow: 'coexistence') }
      .to raise_error(described_class::ResolutionError) do |error|
        expect(error.error_code).to eq('coexistence_identity_mismatch')
      end
  end

  it 'fails closed when a WABA phone-number listing is malformed' do
    allow(api_client).to receive(:fetch_phone_numbers).and_return('data' => { 'id' => '20002' })

    expect { resolve }
      .to raise_error(described_class::ResolutionError) { |error| expect(error.error_code).to eq('asset_page_unreadable') }
  end
end
