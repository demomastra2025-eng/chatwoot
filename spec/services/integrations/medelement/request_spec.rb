require 'rails_helper'

RSpec.describe Integrations::Medelement::Request do
  subject(:request) do
    described_class.new(
      configuration: configuration,
      sleeper: ->(seconds) { sleeps << seconds },
      randomizer: ->(_minimum, maximum) { maximum },
      rate_limiter: rate_limiter
    )
  end

  let(:configuration) do
    instance_double(
      Integrations::Medelement::Configuration,
      company_login: 'clinic-login',
      password: 'secret',
      integrator_key: 'integrator-key',
      organization_id: 'company-1',
      throttle_ms: 200
    )
  end
  let(:rate_limiter) { instance_double(Integrations::Medelement::RequestRateLimiter, wait!: nil) }
  let(:sleeps) { [] }
  let(:base_url) { Integrations::Medelement::Client::BASE_URL }

  describe '#call' do
    it 'does not retry a timetable rate limit when the caller opts out' do
      provider_request = stub_request(:get, "#{base_url}/v1/timetable/get_timetable")
                         .to_return(status: 429, body: '{}', headers: { 'Content-Type' => 'application/json' })

      expect do
        request.call(:get, '/v1/timetable/get_timetable', operation: 'timetable', retry_429: false)
      end.to raise_error(Integrations::Medelement::Client::ApiError) { |error| expect(error.status).to eq(429) }

      expect(provider_request).to have_been_requested.once
      expect(rate_limiter).to have_received(:wait!).once
      expect(sleeps).to be_empty
    end

    it 'retries safe reads with exponential backoff and stops after the retry limit' do
      provider_request = stub_request(:get, "#{base_url}/doctor/v1/patient/patient-1")
                         .to_return(Array.new(8) do
                           { status: 429, body: '{}', headers: { 'Content-Type' => 'application/json' } }
                         end)

      expect do
        request.call(:get, '/doctor/v1/patient/patient-1', operation: 'patient')
      end.to raise_error(Integrations::Medelement::Client::ApiError) { |error| expect(error.status).to eq(429) }

      expect(provider_request).to have_been_requested.times(8)
      expect(rate_limiter).to have_received(:wait!).exactly(8).times
      expect(sleeps).to eq([5.0, 10.0, 20.0, 40.0, 80.0, 160.0, 300.0])
    end

    it 'retries a failing read of a command only twice and quickly, because someone waits for the answer' do
      command_request = described_class.new(
        configuration: configuration, sleeper: ->(seconds) { sleeps << seconds }, randomizer: ->(_minimum, maximum) { maximum },
        rate_limiter: rate_limiter, retry_profile: :command
      )
      provider_request = stub_request(:get, "#{base_url}/doctor/v1/patient/patient-1")
                         .to_return(Array.new(3) { { status: 503, body: '{}', headers: { 'Content-Type' => 'application/json' } } })

      expect do
        command_request.call(:get, '/doctor/v1/patient/patient-1', operation: 'patient')
      end.to raise_error(Integrations::Medelement::Client::ApiError) { |error| expect(error.status).to eq(503) }

      expect(provider_request).to have_been_requested.times(3)
      expect(sleeps).to eq([1.0, 2.0])
    end

    it 'honors Retry-After while capping a provider delay at five minutes' do
      provider_request = stub_request(:get, "#{base_url}/doctor/v1/patient/patient-1")
                         .to_return(
                           { status: 429, body: '{}', headers: { 'Content-Type' => 'application/json', 'Retry-After' => '900' } },
                           {
                             status: 200,
                             body: { PROFILE_CODE: 'patient-1' }.to_json,
                             headers: { 'Content-Type' => 'application/json' }
                           }
                         )

      result = request.call(:get, '/doctor/v1/patient/patient-1', operation: 'patient')

      expect(result).to include('PROFILE_CODE' => 'patient-1')
      expect(provider_request).to have_been_requested.times(2)
      expect(sleeps).to eq([300.0])
    end

    it 'retries a safe read after a transient transport failure' do
      provider_request = stub_request(:get, "#{base_url}/doctor/v1/patient/patient-1")
                         .to_raise(Errno::ECONNRESET)
                         .then.to_return(
                           status: 200,
                           body: { PROFILE_CODE: 'patient-1' }.to_json,
                           headers: { 'Content-Type' => 'application/json' }
                         )

      result = request.call(:get, '/doctor/v1/patient/patient-1', operation: 'patient')

      expect(result).to include('PROFILE_CODE' => 'patient-1')
      expect(provider_request).to have_been_requested.times(2)
      expect(sleeps).to eq([5.0])
    end

    it 'fails closed when the distributed limiter is unavailable' do
      provider_request = stub_request(:get, "#{base_url}/doctor/v1/patient/patient-1")
      allow(rate_limiter).to receive(:wait!).and_raise(
        Integrations::Medelement::RequestRateLimiter::UnavailableError,
        'Medelement request pacing is unavailable (Redis::CannotConnectError)'
      )

      expect do
        request.call(:get, '/doctor/v1/patient/patient-1', operation: 'patient')
      end.to raise_error(
        Integrations::Medelement::Client::ApiError,
        'Medelement patient transport failed: Integrations::Medelement::RequestRateLimiter::UnavailableError'
      )

      expect(provider_request).not_to have_been_requested
      expect(rate_limiter).to have_received(:wait!).exactly(8).times
      expect(sleeps).to eq([5.0, 10.0, 20.0, 40.0, 80.0, 160.0, 300.0])
    end

    it 'takes a slot of the request type for every attempt, a write with its own larger cap' do
      stub_request(:get, "#{base_url}/doctor/v1/patient/patient-1")
        .to_return({ status: 503, body: '{}' }, { status: 200, body: { PROFILE_CODE: 'patient-1' }.to_json,
                                                  headers: { 'Content-Type' => 'application/json' } })
      stub_request(:post, "#{base_url}/v1/doctor/reception")
        .to_return(status: 200, body: { reception_code: '1' }.to_json, headers: { 'Content-Type' => 'application/json' })

      request.call(:get, '/doctor/v1/patient/patient-1', operation: 'patient')
      request.call(:post, '/v1/doctor/reception', operation: 'reception create', body: 'a=b', write: true)

      expect(rate_limiter).to have_received(:wait!).with(operation: 'patient', write: false).twice
      expect(rate_limiter).to have_received(:wait!).with(operation: 'reception create', write: true).once
    end

    it 'does not send the request and raises a retryable error when the slot of its type is busy for too long' do
      provider_request = stub_request(:post, "#{base_url}/v2/doctor/reception/change_reception_date")
      allow(rate_limiter).to receive(:wait!).and_raise(
        Integrations::Medelement::RequestRateLimiter::BusyError.new(operation: 'reception move', retry_after_ms: 4200, write: true)
      )

      expect do
        request.call(:post, '/v2/doctor/reception/change_reception_date', operation: 'reception move', body: 'a=b', write: true)
      end.to raise_error(Integrations::Medelement::Client::RateLimitedError) do |error|
        expect(error).to have_attributes(operation: 'reception move', retry_after_ms: 4200, status: nil)
        expect(error).to be_retryable
        expect(error).not_to be_ambiguous
        expect(error).to be_write
      end

      expect(provider_request).not_to have_been_requested
      expect(sleeps).to be_empty
    end

    it 'does not automatically retry side-effectful writes' do
      provider_request = stub_request(:post, "#{base_url}/doctor/v1/patient")
                         .to_return(
                           { status: 429, body: '{}', headers: { 'Content-Type' => 'application/json' } },
                           { status: 201, body: '{}', headers: { 'Content-Type' => 'application/json' } }
                         )

      perform_request = lambda do
        request.call(:post, '/doctor/v1/patient', operation: 'patient create', body: 'name=value', write: true)
      end
      expect(&perform_request).to raise_error(Integrations::Medelement::Client::ApiError) do |error|
        expect(error.status).to eq(429)
        expect(error).to be_ambiguous
      end

      expect(provider_request).to have_been_requested.once
      expect(rate_limiter).to have_received(:wait!).once
      expect(sleeps).to be_empty
    end
  end

  describe '#indexed_get' do
    it 'applies the same retry policy to indexed Net::HTTP reads' do
      provider_request = stub_request(:get, "#{base_url}/doctor/v1/patients")
                         .with(query: { 'patient_code[]' => 'patient-1', 'skip' => '0' })
                         .to_return(
                           { status: 503, body: '{}', headers: { 'Content-Type' => 'application/json' } },
                           {
                             status: 200,
                             body: [{ PROFILE_CODE: 'patient-1' }].to_json,
                             headers: { 'Content-Type' => 'application/json' }
                           }
                         )

      result = request.indexed_get(
        '/doctor/v1/patients',
        query: URI.encode_www_form([['patient_code[]', 'patient-1'], ['skip', 0]]),
        operation: 'patient search'
      )

      expect(result).to contain_exactly(include('PROFILE_CODE' => 'patient-1'))
      expect(provider_request).to have_been_requested.times(2)
      expect(sleeps).to eq([5.0])
    end
  end

  describe '#receptions' do
    it 'retries the provider read-only POST endpoint' do
      provider_request = stub_request(:post, "#{base_url}/v1/timetable/get_receptions")
                         .to_return(
                           { status: 500, body: '{}', headers: { 'Content-Type' => 'application/json' } },
                           {
                             status: 200,
                             body: { receptions: [] }.to_json,
                             headers: { 'Content-Type' => 'application/json' }
                           }
                         )

      result = request.receptions(
        company_cabinet_code: 'cabinet-1',
        specialist_code: 'specialist-1',
        begin_datetime: '01.08.2026 00:00:00',
        end_datetime: '31.08.2026 23:59:59'
      )

      expect(result).to eq([])
      expect(provider_request).to have_been_requested.times(2)
      expect(sleeps).to eq([5.0])
    end
  end

  describe 'a busy request slot' do
    before do
      allow(rate_limiter).to receive(:wait!).and_raise(
        Integrations::Medelement::RequestRateLimiter::BusyError.new(operation: 'receptions', retry_after_ms: 3500)
      )
    end

    it 'is reported as a retryable error by every kind of read, and nothing is sent' do
      provider_request = stub_request(:any, /api3.medelement.com/)

      expect { request.indexed_get('/doctor/v1/patients', query: 'skip=0', operation: 'patient search') }
        .to raise_error(Integrations::Medelement::Client::RateLimitedError) do |error|
          expect(error.retry_after_ms).to eq(3500)
          expect(error).not_to be_write
        end
      expect do
        request.receptions(company_cabinet_code: 'cabinet-1', specialist_code: 'specialist-1',
                           begin_datetime: '01.08.2026 00:00:00', end_datetime: '31.08.2026 23:59:59')
      end.to raise_error(Integrations::Medelement::Client::RateLimitedError) { |error| expect(error).to be_retryable }
      expect(provider_request).not_to have_been_requested
    end
  end
end
