require 'rails_helper'

RSpec.describe Integrations::Macrocrm::Client do
  let(:hook) do
    instance_double(
      Integrations::Hook,
      access_token: 'macro-secret',
      settings: { 'app_id' => 'macro-app' }
    )
  end
  let(:client) { described_class.new(hook: hook) }

  def response(status, body)
    instance_double(HTTParty::Response, success?: status.between?(200, 299), code: status, parsed_response: body)
  end

  before do
    allow(client).to receive(:sleep)
  end

  describe '#find_contact' do
    it 'normalizes MacroCRM contact-not-found 404 responses as a missing contact' do
      allow(HTTParty).to receive(:post)
        .and_return(response(404, 'No contacts found'))

      expect(client.find_contact(phone: '+770****4567')).to eq(
        'error' => true,
        'message' => 'No contacts found'
      )
      expect(HTTParty).to have_received(:post).once
    end

    it 'normalizes MacroCRM contact-not-found 404 message hashes as a missing contact' do
      allow(HTTParty).to receive(:post)
        .and_return(response(404, { 'message' => 'No contacts found' }))

      expect(client.find_contact(phone: '+770****4567')).to eq(
        'error' => true,
        'message' => 'No contacts found'
      )
      expect(HTTParty).to have_received(:post).once
    end

    it 'keeps unrelated 404 responses as permanent errors' do
      allow(HTTParty).to receive(:post)
        .and_return(response(404, { 'message' => 'Endpoint not found' }))

      expect { client.find_contact(phone: '+770****4567') }
        .to raise_error(described_class::PermanentError, /HTTP 404/)
      expect(HTTParty).to have_received(:post).once
    end

    it 'retries a transient timeout on lookup endpoints' do
      attempts = 0
      allow(HTTParty).to receive(:post) do
        attempts += 1
        raise Net::ReadTimeout, 'execution expired' if attempts == 1

        response(200, { 'contact' => { 'id' => 123 } })
      end

      expect(client.find_contact(phone: '+77001234567')).to eq('contact' => { 'id' => 123 })
      expect(HTTParty).to have_received(:post).twice
      expect(client).to have_received(:sleep).with(0.25)
    end

    it 'raises a transient error after retryable upstream failures are exhausted' do
      allow(HTTParty).to receive(:post)
        .and_return(response(502, { 'error' => 'bad gateway' }))

      expect { client.find_contact(phone: '+77001234567') }
        .to raise_error(described_class::TransientError, /HTTP 502/)
      expect(HTTParty).to have_received(:post).twice
    end

    it 'raises a permanent error for non-retryable client errors' do
      allow(HTTParty).to receive(:post)
        .and_return(response(422, { 'error' => 'invalid phone', 'customer' => '+77001234567' }))

      expect { client.find_contact(phone: 'bad') }
        .to raise_error(described_class::PermanentError, /HTTP 422/)
      expect(HTTParty).to have_received(:post).once
    end

    it 'does not expose raw upstream response bodies in exception messages' do
      allow(HTTParty).to receive(:post)
        .and_return(response(422, { 'customer' => '+77001234567' }))

      expect { client.find_contact(phone: 'bad') }
        .to raise_error(described_class::PermanentError) { |error| expect(error.message).not_to include('+77001234567', 'customer') }
    end
  end

  describe '#add_note' do
    it 'does not automatically retry unknown-outcome timeouts for non-idempotent writes' do
      allow(HTTParty).to receive(:post)
        .and_raise(Net::ReadTimeout.new('execution expired'))

      expect { client.add_note(estate_id: 123, note: 'hello') }
        .to raise_error(described_class::UnknownOutcomeError, /not retrying non-idempotent/)
      expect(HTTParty).to have_received(:post).once
    end

    it 'does not automatically retry transient HTTP failures for non-idempotent writes' do
      allow(HTTParty).to receive(:post)
        .and_return(response(502, { 'error' => 'bad gateway' }))

      expect { client.add_note(estate_id: 123, note: 'hello') }
        .to raise_error(described_class::UnknownOutcomeError, /not retrying non-idempotent/)
      expect(HTTParty).to have_received(:post).once
    end
  end
end
