# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telephony::Wazo::ApiClient do
  subject(:client) do
    described_class.new(
      base_url: 'https://wazo.example.com',
      username: 'onelink-provisioner',
      password: 'api-password',
      tenant_uuid: 'tenant-uuid'
    )
  end

  it 'authenticates and lists SIP endpoints with the scoped Wazo tenant' do
    stub_request(:post, 'https://wazo.example.com/api/auth/0.1/token')
      .with(basic_auth: %w[onelink-provisioner api-password])
      .to_return(status: 200, body: { data: { token: 'token-value' } }.to_json, headers: { 'Content-Type' => 'application/json' })
    request = stub_request(:get, 'https://wazo.example.com/api/confd/1.1/endpoints/sip?limit=1000')
              .with(headers: { 'X-Auth-Token' => 'token-value', 'Wazo-Tenant' => 'tenant-uuid' })
              .to_return(
                status: 200, body: { items: [{ uuid: 'uuid-1', name: 'endpoint-1' }] }.to_json,
                headers: { 'Content-Type' => 'application/json' }
              )

    expect(client.sip_endpoints).to eq([{ 'uuid' => 'uuid-1', 'name' => 'endpoint-1' }])
    expect(request).to have_been_requested.once
  end

  it 'rejects non-HTTPS API URLs' do
    expect do
      described_class.new(base_url: 'http://wazo.example.com', username: 'user', password: 'secret')
    end.to raise_error(Telephony::Error) { |error| expect(error.code).to eq('WAZO_API_URL_INVALID') }
  end

  it 'does not include credentials or response bodies in request errors' do
    stub_request(:post, 'https://wazo.example.com/api/auth/0.1/token')
      .to_return(status: 401, body: 'api-password should never escape')

    expect { client.sip_endpoints }.to raise_error(Telephony::Error) do |error|
      expect(error.message).to eq('Wazo API request failed with HTTP 401')
      expect(error.message).not_to include('api-password')
    end
  end

  it 'uses the Confd graph resource and association paths with tenant isolation', :aggregate_failures do
    stub_request(:post, 'https://wazo.example.com/api/auth/0.1/token')
      .to_return(status: 200, body: { data: { token: 'token-value' } }.to_json)
    headers = { 'X-Auth-Token' => 'token-value', 'Wazo-Tenant' => 'tenant-uuid' }
    user_request = stub_request(:post, 'https://wazo.example.com/api/confd/1.1/users')
                   .with(headers: headers).to_return(status: 201, body: { uuid: 'user-uuid' }.to_json)
    line_request = stub_request(:post, 'https://wazo.example.com/api/confd/1.1/lines')
                   .with(headers: headers).to_return(status: 201, body: { id: 12 }.to_json)
    extension_request = stub_request(:post, 'https://wazo.example.com/api/confd/1.1/extensions')
                        .with(headers: headers).to_return(status: 201, body: { id: 13 }.to_json)
    user_line_request = stub_request(:put, 'https://wazo.example.com/api/confd/1.1/users/user-uuid/lines/12')
                        .with(headers: headers).to_return(status: 204)
    line_extension_request = stub_request(:put, 'https://wazo.example.com/api/confd/1.1/lines/12/extensions/13')
                             .with(headers: headers).to_return(status: 204)
    line_endpoint_request = stub_request(:put, 'https://wazo.example.com/api/confd/1.1/lines/12/endpoints/sip/endpoint-uuid')
                            .with(headers: headers).to_return(status: 204)

    client.create_user({ firstname: 'Operator' })
    client.create_line({ context: 'onelink-test' })
    client.create_extension({ context: 'onelink-test', exten: '101' })
    client.associate_user_line('user-uuid', 12)
    client.associate_line_extension(12, 13)
    client.associate_line_sip_endpoint(12, 'endpoint-uuid')

    expect(user_request).to have_been_requested.once
    expect(line_request).to have_been_requested.once
    expect(extension_request).to have_been_requested.once
    expect(user_line_request).to have_been_requested.once
    expect(line_extension_request).to have_been_requested.once
    expect(line_endpoint_request).to have_been_requested.once
  end
end
