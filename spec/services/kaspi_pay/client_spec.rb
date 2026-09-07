require 'rails_helper'

RSpec.describe KaspiPay::Client do
  let(:secret_settings) do
    {
      'token_sn' => 'token-sn',
      'vtoken_secret' => 'encrypted-secret',
      'profile_id' => 'profile-1',
      'organization_id' => 'org-1'
    }
  end
  let(:hook) { instance_double(Integrations::Hook, secret_settings: secret_settings) }
  let(:internal_secret) { 'internal-secret' }
  let(:timestamp) { Time.zone.at(1_700_000_000) }
  let(:client) { described_class.new(hook: hook, adapter_url: 'http://kaspi-adapter.test', internal_secret: internal_secret) }

  before do
    allow(Time).to receive(:current).and_return(timestamp)
  end

  describe 'authentication requests' do
    it 'binds init to the account in the HMAC-signed body' do
      expected_body = { accountId: 530, authFlowVersion: 2 }.to_json
      request = stub_request(:post, 'http://kaspi-adapter.test/internal/kaspi/auth/init')
                .with(body: expected_body, headers: internal_headers('POST', '/internal/kaspi/auth/init', expected_body))
                .to_return(status: 200, body: { success: true, processId: 'flow-1' }.to_json)

      client.init(account_id: 530, auth_flow_version: 2)

      expect(request).to have_been_requested
    end

    it 'sends the password only in the HMAC-signed adapter request body' do
      expected_body = { processId: 'flow-1', password: 'cashier-password', accountId: 530 }.to_json
      request = stub_request(:post, 'http://kaspi-adapter.test/internal/kaspi/auth/send-password')
                .with(
                  body: expected_body,
                  headers: internal_headers('POST', '/internal/kaspi/auth/send-password', expected_body)
                )
                .to_return(status: 200, body: { success: true, nextStep: 'otp' }.to_json)

      client.send_password(process_id: 'flow-1', password: 'cashier-password', account_id: 530)

      expect(request).to have_been_requested
    end

    it 'preserves a typed auth flow error and HTTP status from the adapter' do
      stub_request(:post, 'http://kaspi-adapter.test/internal/kaspi/auth/send-password')
        .to_return(
          status: 410,
          body: { success: false, error: 'Authentication expired', code: 'AUTH_FLOW_EXPIRED' }.to_json
        )

      expect { client.send_password(process_id: 'flow-1', password: 'cashier-password', account_id: 530) }
        .to raise_error(KaspiPay::Error) do |error|
          expect(error.code).to eq('AUTH_FLOW_EXPIRED')
          expect(error.status).to eq(410)
        end
    end
  end

  describe '#create_qr' do
    it 'sends Kaspi session credentials as internal headers, not request body fields' do
      expected_body = { amount: 15_000, latitude: 43.238949, longitude: 76.889709 }.to_json
      request = stub_request(:post, 'http://kaspi-adapter.test/internal/kaspi/qr/create')
                .with(
                  body: expected_body,
                  headers: internal_headers('POST', '/internal/kaspi/qr/create', expected_body).merge(session_headers)
                )
                .to_return(status: 200, body: { 'StatusCode' => 0, 'Data' => { 'QrOperationId' => 'qr-1' } }.to_json)

      client.create_qr(amount: 15_000, latitude: 43.238949, longitude: 76.889709)

      expect(request).to have_been_requested
    end
  end

  describe '#qr_status' do
    it 'keeps Kaspi session credentials out of the query string' do
      request = stub_request(:get, 'http://kaspi-adapter.test/internal/kaspi/qr/status?qrOperationId=qr-1')
                .with(headers: internal_headers('GET', '/internal/kaspi/qr/status?qrOperationId=qr-1', '').merge(session_headers))
                .to_return(status: 200, body: { 'StatusCode' => 0, 'Data' => { 'Status' => 'Processed' } }.to_json)

      client.qr_status('qr-1')

      expect(request).to have_been_requested
    end
  end

  describe '#render_qr_png' do
    it 'renders a Kaspi Unified QR through the HMAC-protected adapter without session headers' do
      qr_token = 'https://qr.kaspi.kz/original-token'
      expected_body = { qrToken: qr_token }.to_json
      png = "\x89PNG\r\n\x1A\nqr-image".b
      request = stub_request(:post, 'http://kaspi-adapter.test/internal/kaspi/qr/render')
                .with(
                  body: expected_body,
                  headers: internal_headers('POST', '/internal/kaspi/qr/render', expected_body).merge('Content-Type' => 'application/json')
                )
                .to_return(status: 200, body: png, headers: { 'Content-Type' => 'image/png' })

      expect(client.render_qr_png(qr_token)).to eq(png)
      expect(request).to have_been_requested
    end

    it 'rejects a non-PNG adapter response' do
      stub_request(:post, 'http://kaspi-adapter.test/internal/kaspi/qr/render')
        .to_return(status: 200, body: 'not-an-image', headers: { 'Content-Type' => 'text/plain' })

      expect { client.render_qr_png('https://qr.kaspi.kz/original-token') }
        .to raise_error(KaspiPay::Error) { |error| expect(error.code).to eq('QR_RENDER_INVALID_RESPONSE') }
    end
  end

  describe '#create_invoice' do
    it 'sends remote invoice payload with session credentials in headers only' do
      expected_body = { phoneNumber: '77011234567', amount: 15_000, comment: 'Order 1' }.to_json
      request = stub_request(:post, 'http://kaspi-adapter.test/internal/kaspi/invoice/create')
                .with(
                  body: expected_body,
                  headers: internal_headers('POST', '/internal/kaspi/invoice/create', expected_body).merge(session_headers)
                )
                .to_return(status: 200, body: { 'StatusCode' => 0, 'Data' => { 'Id' => 'remote-1' } }.to_json)

      client.create_invoice(phone_number: '77011234567', amount: 15_000, comment: 'Order 1')

      expect(request).to have_been_requested
    end
  end

  describe '#client_info' do
    it 'looks up an invoice client with session credentials kept in headers' do
      request = stub_request(:get, 'http://kaspi-adapter.test/internal/kaspi/invoice/client-info?phoneNumber=77011234567')
                .with(headers: internal_headers('GET', '/internal/kaspi/invoice/client-info?phoneNumber=77011234567', '').merge(session_headers))
                .to_return(status: 200, body: { 'StatusCode' => 0, 'Data' => { 'ClientName' => 'Test Client' } }.to_json)

      client.client_info('77011234567')

      expect(request).to have_been_requested
    end
  end

  describe '#invoice_details' do
    it 'keeps invoice session credentials out of the query string' do
      request = stub_request(:get, 'http://kaspi-adapter.test/internal/kaspi/invoice/details?operationId=remote-1')
                .with(headers: internal_headers('GET', '/internal/kaspi/invoice/details?operationId=remote-1', '').merge(session_headers))
                .to_return(status: 200, body: { 'StatusCode' => 0, 'Data' => { 'Status' => 'Processed' } }.to_json)

      client.invoice_details('remote-1')

      expect(request).to have_been_requested
    end
  end

  describe '#operation_details' do
    it 'requests operation details for refund reconciliation' do
      expected_body = { id: '15530881826', operationMethod: 0 }.to_json
      request = stub_request(:post, 'http://kaspi-adapter.test/internal/kaspi/history/details')
                .with(
                  body: expected_body,
                  headers: internal_headers('POST', '/internal/kaspi/history/details', expected_body).merge(session_headers)
                )
                .to_return(status: 200, body: { 'StatusCode' => 0, 'Data' => { 'Returns' => [{ 'Amount' => 100 }] } }.to_json)

      client.operation_details('15530881826', operation_method: 0)

      expect(request).to have_been_requested
    end
  end

  describe '#create_refund' do
    it 'sends refund creation payload with session credentials in headers only' do
      expected_body = { qrOperationId: '15530881826', returnAmount: 100 }.to_json
      request = stub_request(:post, 'http://kaspi-adapter.test/internal/kaspi/refund/create')
                .with(
                  body: expected_body,
                  headers: internal_headers('POST', '/internal/kaspi/refund/create', expected_body).merge(session_headers)
                )
                .to_return(status: 200, body: { 'StatusCode' => 0, 'Data' => { 'Status' => 'Returned' } }.to_json)

      client.create_refund(qr_operation_id: '15530881826', return_amount: 100)

      expect(request).to have_been_requested
    end
  end

  describe 'configuration validation' do
    it 'raises a typed service-unavailable error when adapter URL is missing' do
      expect { described_class.new(adapter_url: nil, internal_secret: internal_secret).init }
        .to raise_error(KaspiPay::Error) { |error|
          expect(error.code).to eq('ADAPTER_NOT_CONFIGURED')
          expect(error.status).to eq(503)
        }
    end

    it 'raises a typed service-unavailable error when adapter URL is not HTTP' do
      expect { described_class.new(adapter_url: 'kaspi-adapter.test', internal_secret: internal_secret).init }
        .to raise_error(KaspiPay::Error) { |error|
          expect(error.code).to eq('ADAPTER_URL_INVALID')
          expect(error.status).to eq(503)
        }
    end

    it 'raises a typed service-unavailable error when internal secret is missing' do
      expect { described_class.new(adapter_url: 'http://kaspi-adapter.test', internal_secret: nil).init }
        .to raise_error(KaspiPay::Error) { |error|
          expect(error.code).to eq('ADAPTER_SECRET_NOT_CONFIGURED')
          expect(error.status).to eq(503)
        }
    end
  end

  def internal_headers(method, path, body)
    timestamp_header = timestamp.to_i.to_s
    {
      'X-OneLink-Timestamp' => timestamp_header,
      'X-OneLink-Internal-Signature' => OpenSSL::HMAC.hexdigest('SHA256', internal_secret, [method, path, timestamp_header, body].join("\n"))
    }
  end

  def session_headers
    {
      'X-Token-SN' => 'token-sn',
      'X-Vtoken-Secret' => 'encrypted-secret',
      'X-Profile-ID' => 'profile-1',
      'X-Organization-ID' => 'org-1'
    }
  end
end
