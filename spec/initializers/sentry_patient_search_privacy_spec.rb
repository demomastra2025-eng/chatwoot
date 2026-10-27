require 'rails_helper'
require 'sentry-ruby'

RSpec.describe SentryPatientSearchPrivacy do
  def sentry_request(path, body)
    env = Rack::MockRequest.env_for(path, method: 'POST', input: body)
    env['CONTENT_TYPE'] = 'application/json'
    Sentry::RequestInterface.new(env: env, send_default_pii: true, rack_env_whitelist: [])
  end

  it 'removes patient search and import bodies from Sentry events' do
    {
      '/api/v1/accounts/1/scheduling/medelement_patients/search' => '{"query":"000000000000"}',
      '/api/v1/accounts/1/scheduling/medelement_patients' => '{"token":"fake-token"}'
    }.each do |path, body|
      request = sentry_request(path, body)
      event = Struct.new(:request).new(request)
      expect(request.data).to eq(body)

      expect(described_class.redact_request!(event)).to equal(event)
      expect(request.data).to be_nil
    end
  end

  it 'keeps unrelated request bodies available for existing diagnostics' do
    body = '{"value":"example"}'
    request = sentry_request('/api/v1/accounts/1/scheduling/contacts', body)

    described_class.redact_request!(Struct.new(:request).new(request))

    expect(request.data).to eq(body)
  end
end
