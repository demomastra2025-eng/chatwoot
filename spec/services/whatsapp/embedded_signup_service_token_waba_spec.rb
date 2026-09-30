require 'rails_helper'

# Mobile Embedded Signup: the browser delivered only the FB.login auth code.
describe Whatsapp::EmbeddedSignupService do
  let(:account) { create(:account) }
  let(:access_token) { 'business_token' }
  let(:channel) { instance_double(Channel::Whatsapp) }
  let(:phone_info) { { phone_number_id: '222', phone_number: '+77010000000', verified: true, business_name: 'Clinic' } }
  let(:resolver) { instance_double(Whatsapp::EmbeddedSignupWabaResolver, perform: '111') }

  before do
    allow(GlobalConfigService).to receive(:load).and_call_original
    allow(GlobalConfigService).to receive(:load)
      .with('WHATSAPP_REQUIRE_NON_EXPIRING_SYSTEM_USER_TOKEN', false).and_return(false)
    allow(Whatsapp::TokenExchangeService).to receive(:new).with('mobile_code')
                                                          .and_return(instance_double(Whatsapp::TokenExchangeService, perform: access_token))
    allow(Whatsapp::EmbeddedSignupWabaResolver).to receive(:new).with(access_token).and_return(resolver)
    allow(Whatsapp::PhoneInfoService).to receive(:new).and_return(instance_double(Whatsapp::PhoneInfoService, perform: phone_info))
    allow(Whatsapp::TokenValidationService).to receive(:new)
      .and_return(instance_double(Whatsapp::TokenValidationService, perform: { 'status' => 'healthy' }))
    allow(Whatsapp::ChannelCreationService).to receive(:new)
      .and_return(instance_double(Whatsapp::ChannelCreationService, perform: channel))
    allow(channel).to receive(:store_token_health!)
    allow(channel).to receive(:setup_webhooks).and_return(true)
  end

  it 'reads the shared WABA from the business token and picks the only number' do
    service = described_class.new(account: account, params: { code: 'mobile_code', signup_type: 'standard' },
                                  resolve_waba_from_token: true)

    expect(service.perform).to eq(channel)
    expect(Whatsapp::PhoneInfoService).to have_received(:new).with('111', nil, access_token, allow_unambiguous_selection: true)
    expect(Whatsapp::TokenValidationService).to have_received(:new)
      .with(access_token, '111', phone_number_id: '222', require_non_expiring_system_user: false)
    expect(Whatsapp::ChannelCreationService).to have_received(:new)
      .with(account, { waba_id: '111', business_id: nil, business_name: 'Clinic' }, phone_info, access_token)
    expect(service.waba_source).to eq('token_scope')
  end

  it 'prefers the WABA from Meta session event when the browser delivered it' do
    service = described_class.new(account: account, params: { code: 'mobile_code', waba_id: '333' },
                                  resolve_waba_from_token: true)

    service.perform

    expect(Whatsapp::EmbeddedSignupWabaResolver).not_to have_received(:new)
    expect(Whatsapp::PhoneInfoService).to have_received(:new).with('333', nil, access_token, allow_unambiguous_selection: true)
    expect(service.waba_source).to eq('session_event')
  end

  it 'still requires waba_id when the token fallback was not requested' do
    service = described_class.new(account: account, params: { code: 'mobile_code' })

    expect { service.perform }.to raise_error(ArgumentError, /waba_id/)
    expect(Whatsapp::TokenExchangeService).not_to have_received(:new)
  end

  it 'never creates a channel when the token does not identify one WABA' do
    allow(resolver).to receive(:perform)
      .and_raise(Whatsapp::EmbeddedSignupWabaResolver::ResolutionError.new('waba_ambiguous', 'several'))
    service = described_class.new(account: account, params: { code: 'mobile_code' }, resolve_waba_from_token: true)

    expect { service.perform }.to raise_error(Whatsapp::EmbeddedSignupWabaResolver::ResolutionError)
    expect(Whatsapp::ChannelCreationService).not_to have_received(:new)
  end
end
