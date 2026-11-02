require 'rails_helper'

RSpec.describe Whatsapp::ProviderConfigPresenter do
  it 'omits raw call routing without mutating config or removing fields used by other presenter callers' do
    config = {
      'call_routing' => { 'inbound' => { 'archive' => { 'system_prompt' => 'PRIVATE_WA_ROUTING_ARCHIVE' } } },
      'api_key' => 'PRIVATE_WA_TRANSPORT_SECRET', 'calling_enabled' => false, 'ai_voice_enabled' => false,
      'phone_registration' => { 'status' => 'registered' }, 'whatsapp_flows' => { 'booking_locale' => 'kk' }
    }
    channel = build_stubbed(:channel_whatsapp, provider: 'whatsapp_cloud', provider_config: config)
    saved = channel.provider_config.deep_dup

    result = described_class.new(channel).perform

    expect(result).not_to have_key('call_routing')
    expect(result.to_json).not_to include('PRIVATE_WA_ROUTING_ARCHIVE', 'PRIVATE_WA_TRANSPORT_SECRET')
    expect(result).to include('calling_enabled' => false, 'ai_voice_enabled' => false,
                              'phone_registration' => { 'status' => 'registered' }, 'whatsapp_flows' => { 'booking_locale' => 'kk' })
    expect(channel.provider_config).to eq(saved)
  end
end
