require 'rails_helper'

RSpec.describe Whatsapp::TokenHealthCheckChannelJob do
  let(:health_service) { instance_double(Whatsapp::TokenHealthCheckService, perform: true) }

  before do
    allow(Whatsapp::TokenHealthCheckService).to receive(:new).and_return(health_service)
  end

  it 'checks an active WhatsApp Cloud channel' do
    channel = create(:channel_whatsapp, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false)

    described_class.perform_now(channel.id)

    expect(Whatsapp::TokenHealthCheckService).to have_received(:new).with(channel)
    expect(health_service).to have_received(:perform)
  end

  it 'ignores non-Cloud, missing, and suspended-account channels' do
    default_channel = create(:channel_whatsapp, provider: 'default', sync_templates: false, validate_provider_config: false)
    suspended_channel = create(
      :channel_whatsapp,
      provider: 'whatsapp_cloud',
      account: create(:account, status: 'suspended'),
      sync_templates: false,
      validate_provider_config: false
    )

    described_class.perform_now(default_channel.id)
    described_class.perform_now(suspended_channel.id)
    described_class.perform_now(-1)

    expect(Whatsapp::TokenHealthCheckService).not_to have_received(:new)
  end
end
