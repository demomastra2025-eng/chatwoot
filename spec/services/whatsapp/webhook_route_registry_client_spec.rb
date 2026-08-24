require 'rails_helper'

RSpec.describe Whatsapp::WebhookRouteRegistryClient do
  let(:url) { described_class::CANONICAL_URL }
  let(:client) { described_class.new(url: url, secret: 'route-secret', destination: 'dev') }
  let(:registration_token) { '123e4567-e89b-42d3-a456-426614174000' }

  it 'matches the shared Rails and Rust HMAC contract vector' do
    body = '{"waba_id":"123","phone_number_id":"456","destination":"widget"}'

    expect(described_class.signature(
             secret: 'route-secret', method: :put, destination: 'widget', timestamp: '1700000000', body: body
           )).to eq('sha256=a083eab3fe80c13f837151a823a2315008a762693e34d9ce4e6a8e38296e7744')
  end

  it 'registers and unregisters with method-bound signatures' do
    register_request = stub_request(:put, url)
                       .to_return(status: 201, headers: { described_class::REGISTRATION_TOKEN_HEADER => registration_token })
    delete_request = stub_request(:delete, url)
                     .with(
                       body: JSON.generate(
                         waba_id: '123', phone_number_id: '456', destination: 'dev', registration_token: registration_token
                       )
                     )
                     .to_return(status: 204)

    registration = client.register!(waba_id: '123', phone_number_id: '456')
    expect(registration).to have_attributes(status: :created, token: registration_token)
    expect(client.unregister!(waba_id: '123', phone_number_id: '456', registration_token: registration.token)).to be(true)
    expect(register_request).to have_been_requested.once
    expect(delete_request).to have_been_requested.once

    put_signature = request_signature(:put)
    delete_signature = request_signature(:delete)
    expect(put_signature).not_to eq(delete_signature)
  end

  it 'distinguishes an existing route from one created by this request' do
    stub_request(:put, url).to_return(status: 204)

    expect(client.register!(waba_id: '123', phone_number_id: '456')).to have_attributes(status: :existing, token: nil)
  end

  it 'treats a rolling 201 response without a generation token as existing' do
    stub_request(:put, url).to_return(status: 201)

    expect(client.register!(waba_id: '123', phone_number_id: '456')).to have_attributes(status: :existing, token: nil)
  end

  it 'is a no-op in production when client settings are absent' do
    disabled = described_class.new(url: '', secret: '', destination: '')

    expect(disabled.register!(waba_id: '123', phone_number_id: '456')).to be(false)
    expect(WebMock).not_to have_requested(:any, /.*/)
  end

  it 'rejects arbitrary remote registry hosts' do
    invalid = described_class.new(url: 'https://example.test/internal/whatsapp/webhook_routes', secret: 'secret', destination: 'dev')

    expect(invalid).not_to be_configured
  end

  it 'does not include low-level network details in its public error' do
    stub_request(:put, url).to_raise(SocketError.new('secret internal hostname'))

    error = begin
      client.register!(waba_id: '123', phone_number_id: '456')
      nil
    rescue described_class::Error => e
      e
    end

    expect(error).to be_a(described_class::Error)
    expect(error.message).to include('error_class=SocketError')
    expect(error.message).not_to include('secret internal hostname')
  end

  def request_signature(method)
    body = JSON.generate(waba_id: '123', phone_number_id: '456', destination: 'dev')
    described_class.signature(
      secret: 'route-secret',
      method: method,
      destination: 'dev',
      timestamp: '100',
      body: body
    )
  end
end
