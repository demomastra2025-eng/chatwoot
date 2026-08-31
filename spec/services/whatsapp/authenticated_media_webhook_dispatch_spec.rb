# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Whatsapp::AuthenticatedMediaWebhookDispatch do
  let(:channel) { instance_double(Channel::Whatsapp, provider: 'whatsapp_cloud') }
  let(:route) { instance_double(Whatsapp::AuthenticatedWebhookRoute) }
  let(:dispatch_action) { instance_double(Proc) }
  let(:runtime_snapshot) { { channel_id: 7, credential_fingerprint: 'fingerprint' }.with_indifferent_access }

  before do
    allow(Whatsapp::AuthenticatedWebhookRoute).to receive(:new).and_return(route)
  end

  it 'dispatches a payload atomically with the final route verification' do
    expect(route).to receive(:verified_runtime_snapshot).ordered.and_return(runtime_snapshot)
    expect(Whatsapp::CloudMediaDownload).to receive(:prepare).ordered.and_return(nil)
    expect(route).to receive(:with_verified_route)
      .with(expected_runtime_snapshot: runtime_snapshot)
      .ordered
      .and_yield
      .and_return(true)
    expect(dispatch_action).to receive(:call).with(nil).ordered

    expect(service.perform).to be(true)
  end

  it 'fails closed when routing identity changes before a non-media dispatch' do
    allow(route).to receive(:verified_runtime_snapshot).and_return(runtime_snapshot)
    allow(route).to receive(:with_verified_route).and_return(false)
    allow(Whatsapp::CloudMediaDownload).to receive(:prepare).and_return(nil)
    expect(dispatch_action).not_to receive(:call)

    expect { service.perform }.to raise_error(Whatsapp::AuthenticatedWebhookRoute::RuntimeIdentityChangedError)
  end

  it 'downloads outside the lock and dispatches atomically with the final route verification' do
    attachment = instance_double(Whatsapp::CloudMediaDownload, download!: true, close: true)
    expect(route).to receive(:verified_runtime_snapshot).ordered.and_return(runtime_snapshot)
    expect(Whatsapp::CloudMediaDownload).to receive(:prepare).ordered.and_return(attachment)
    expect(attachment).to receive(:download!).ordered
    expect(route).to receive(:with_verified_route)
      .with(expected_runtime_snapshot: runtime_snapshot)
      .ordered
      .and_yield
      .and_return(true)
    expect(dispatch_action).to receive(:call).with(attachment).ordered
    expect(attachment).to receive(:close).ordered

    expect(service.perform).to be(true)
  end

  it 'fails closed when routing identity changes after a media download' do
    attachment = instance_double(Whatsapp::CloudMediaDownload, download!: true, close: true)
    allow(route).to receive(:verified_runtime_snapshot).and_return(runtime_snapshot)
    allow(route).to receive(:with_verified_route).and_return(false)
    allow(Whatsapp::CloudMediaDownload).to receive(:prepare).and_return(attachment)
    expect(dispatch_action).not_to receive(:call)
    expect(attachment).to receive(:close)

    expect { service.perform }.to raise_error(Whatsapp::AuthenticatedWebhookRoute::RuntimeIdentityChangedError)
  end

  def service
    described_class.new(
      channel: channel,
      payload: { entry: [] },
      verification_context: { hmac_verified: true },
      live_priority_token: 'priority-job',
      outgoing_echo: false,
      dispatch_action: dispatch_action
    )
  end
end
