require 'rails_helper'

RSpec.describe Whatsapp::EmbeddedSignupService, '#failure logging' do
  let(:account) { create(:account) }
  let(:oauth_code) { 'one-time-oauth-code' }
  let(:service) do
    described_class.new(
      account: account,
      params: {
        code: oauth_code,
        business_id: 'business-1',
        waba_id: 'waba-1',
        phone_number_id: 'phone-1'
      }
    )
  end

  it 'redacts OAuth codes and provider tokens before logging and preserves the original failure' do
    token_exchange = instance_double(Whatsapp::TokenExchangeService)
    allow(Whatsapp::TokenExchangeService).to receive(:new).with(oauth_code).and_return(token_exchange)
    allow(token_exchange).to receive(:perform)
      .and_raise("exchange failed code=#{oauth_code} access_token=provider-token")
    allow(GlobalConfigService).to receive(:load).with('WHATSAPP_APP_ID', '').and_return('app-id')
    allow(GlobalConfigService).to receive(:load).with('WHATSAPP_APP_SECRET', '').and_return('app-secret')
    logged_message = nil
    allow(Rails.logger).to receive(:error) { |message| logged_message = message }

    expect { service.perform }.to raise_error(/exchange failed/)
    expect(logged_message).to include('[FILTERED]')
    expect(logged_message).not_to include(oauth_code, 'provider-token')
  end
end
