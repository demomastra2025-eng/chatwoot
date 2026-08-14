require 'rails_helper'

RSpec.describe Integrations::Medelement::Client do
  subject(:client) { described_class.new(configuration: configuration) }

  let(:configuration) do
    instance_double(
      Integrations::Medelement::Configuration,
      company_login: 'clinic-login',
      password: 'secret',
      integrator_key: 'integrator-key',
      organization_id: 'company-1'
    )
  end

  describe 'provider organization configuration' do
    before do
      allow(configuration).to receive(:organization_id).and_return(nil)
    end

    it 'fails closed before normal, indexed and empty-receptions reads' do
      expect { client.get_patient(patient_code: 'patient-1') }
        .to raise_error(Integrations::Medelement::ProviderScope::MismatchError)
      expect { client.search_patients_by_codes(patient_codes: ['patient-1']) }
        .to raise_error(Integrations::Medelement::ProviderScope::MismatchError)
      expect do
        client.get_receptions(
          company_cabinet_code: 'cabinet-1',
          specialist_code: 'specialist-1',
          begin_datetime: '01.04.2026 00:00:00',
          end_datetime: '30.04.2026 23:59:59'
        )
      end.to raise_error(Integrations::Medelement::ProviderScope::MismatchError)
    end
  end

  describe '#get_receptions' do
    it 'rejects a foreign organization declared by the response envelope' do
      stub_request(:post, "#{described_class::BASE_URL}/v1/timetable/get_receptions")
        .to_return(
          status: 200,
          body: { companyCode: 'company-2', receptions: [] }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      expect do
        client.get_receptions(
          company_cabinet_code: 'cabinet-1',
          specialist_code: 'specialist-1',
          begin_datetime: '01.04.2026 00:00:00',
          end_datetime: '30.04.2026 23:59:59'
        )
      end.to raise_error(Integrations::Medelement::ProviderScope::MismatchError)
    end

    it 'treats escaped-unicode 404 empty responses as an empty receptions set' do
      stub_request(:post, "#{described_class::BASE_URL}/v1/timetable/get_receptions")
        .to_return(
          status: 404,
          body: '{"message":"\u041f\u0440\u0438\u0435\u043c\u044b \u043d\u0435 \u043d\u0430\u0439\u0434\u0435\u043d\u044b"}',
          headers: { 'Content-Type' => 'application/json' }
        )

      result = client.get_receptions(
        company_cabinet_code: 'cabinet-1',
        specialist_code: 'specialist-1',
        begin_datetime: '01.04.2026 00:00:00',
        end_datetime: '30.04.2026 23:59:59'
      )

      expect(result).to eq([])
    end

    it 'does not include provider response bodies in API errors' do
      stub_request(:post, "#{described_class::BASE_URL}/v1/timetable/get_receptions")
        .to_return(
          status: 500,
          body: '{"patient_phone":"+77001234567"}',
          headers: { 'Content-Type' => 'application/json' }
        )

      request = lambda do
        client.get_receptions(
          company_cabinet_code: 'cabinet-1',
          specialist_code: 'specialist-1',
          begin_datetime: '01.04.2026 00:00:00',
          end_datetime: '30.04.2026 23:59:59'
        )
      end

      expect(&request).to raise_error(Integrations::Medelement::Client::ApiError) do |error|
        expect(error.status).to eq(500)
        expect(error.message).not_to include('+77001234567')
      end
    end

    it 'normalizes connection resets as retryable API errors without transport details' do
      stub_request(:post, "#{described_class::BASE_URL}/v1/timetable/get_receptions")
        .to_raise(Errno::ECONNRESET)

      request = lambda do
        client.get_receptions(
          company_cabinet_code: 'cabinet-1',
          specialist_code: 'specialist-1',
          begin_datetime: '01.04.2026 00:00:00',
          end_datetime: '30.04.2026 23:59:59'
        )
      end

      expect(&request).to raise_error(
        Integrations::Medelement::Client::ApiError,
        'Medelement receptions transport failed: Errno::ECONNRESET'
      )
    end
  end

  describe '#search_patients_by_phone' do
    it 'uses documented phone components and keeps exact matches only' do
      response = instance_double(
        Net::HTTPOK,
        code: '200',
        body: [
          { 'PROFILE_CODE' => 'exact', 'PATIENT_PHONE_2' => '+7-X-701-X-1234567' },
          { 'PROFILE_CODE' => 'similar', 'PATIENT_PHONE_2' => '+7-X-701-X-1234568' }
        ].to_json
      )
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      http = instance_double(Net::HTTP)
      allow(http).to receive(:request) do |request|
        expect(request.path).to end_with(
          '?patient_phone_2%5B0%5D=7&patient_phone_2%5B1%5D=701&patient_phone_2%5B2%5D=1234567&skip=0'
        )
        response
      end
      allow(Net::HTTP).to receive(:start).and_yield(http)

      result = client.search_patients_by_phone(phone_number: '+77011234567')

      expect(result.pluck('PROFILE_CODE')).to eq(['exact'])
    end

    it 'normalizes the provider 404 empty-array contract' do
      response = instance_double(Net::HTTPNotFound, code: '404', body: '[]')
      allow(Net::HTTP).to receive(:start).and_yield(instance_double(Net::HTTP, request: response))

      expect(client.search_patients_by_phone(phone_number: '+77011234567')).to eq([])
    end
  end

  describe 'write endpoints' do
    it 'routes patient and reception mutations to the documented methods and paths' do
      create_patient = stub_request(:post, "#{described_class::BASE_URL}/doctor/v1/patient")
                       .with(body: hash_including('profile_code' => 'patient-1'))
                       .to_return(status: 201, body: '{"profile_code":"patient-1"}', headers: { 'Content-Type' => 'application/json' })
      update_patient = stub_request(:put, "#{described_class::BASE_URL}/doctor/v1/patient")
                       .with(body: hash_including('profile_code' => 'patient-1'))
                       .to_return(status: 201, body: '{}', headers: { 'Content-Type' => 'application/json' })
      create_reception = stub_request(:post, "#{described_class::BASE_URL}/v1/doctor/reception")
                         .with(body: hash_including('patient_code' => 'patient-1'))
                         .to_return(status: 201, body: '{"RECEPTION_CODE":"reception-1"}', headers: { 'Content-Type' => 'application/json' })
      move_reception = stub_request(:post, "#{described_class::BASE_URL}/v2/doctor/reception/change_reception_date")
                       .with(body: hash_including('paient_code' => 'patient-1', 'reception_code' => 'reception-1'))
                       .to_return(status: 200, body: '{}', headers: { 'Content-Type' => 'application/json' })
      remove_reception = stub_request(:post, "#{described_class::BASE_URL}/v2/doctor/reception/remove")
                         .with(body: { 'reception_code' => 'reception-1' })
                         .to_return(status: 200, body: '{}', headers: { 'Content-Type' => 'application/json' })

      client.create_patient(params: { profile_code: 'patient-1' })
      client.update_patient(params: { profile_code: 'patient-1' })
      client.create_reception(params: { patient_code: 'patient-1' })
      client.move_reception(params: { paient_code: 'patient-1', reception_code: 'reception-1' })
      client.remove_reception(reception_code: 'reception-1')

      expect([create_patient, update_patient, create_reception, move_reception, remove_reception])
        .to all(have_been_requested.once)
    end
  end

  describe 'read-back endpoints' do
    it 'routes patient and both reception versions to the documented paths' do
      patient = stub_request(:get, "#{described_class::BASE_URL}/doctor/v1/patient/patient-1")
                .to_return(status: 200, body: '{"PROFILE_CODE":"patient-1"}', headers: { 'Content-Type' => 'application/json' })
      reception_v1 = stub_request(:get, "#{described_class::BASE_URL}/v1/doctor/reception/reception-1")
                     .to_return(status: 200, body: '{"RECEPTION_CODE":"reception-1"}', headers: { 'Content-Type' => 'application/json' })
      reception_v2 = stub_request(:get, "#{described_class::BASE_URL}/v2/doctor/reception/reception-1")
                     .to_return(status: 200, body: '{"RECEPTION_CODE":"reception-1"}', headers: { 'Content-Type' => 'application/json' })

      client.get_patient(patient_code: 'patient-1')
      client.get_reception(reception_code: 'reception-1', version: :v1)
      client.get_reception(reception_code: 'reception-1')

      expect([patient, reception_v1, reception_v2]).to all(have_been_requested.once)
    end

    it 'rejects an explicit provider organization mismatch without exposing either code' do
      allow(configuration).to receive(:organization_id).and_return('company-1')
      stub_request(:get, "#{described_class::BASE_URL}/doctor/v1/patient/patient-1")
        .to_return(
          status: 200,
          body: { 'PROFILE_CODE' => 'patient-1', 'COMPANY_CODE' => 'company-2' }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      expect { client.get_patient(patient_code: 'patient-1') }
        .to raise_error(Integrations::Medelement::ProviderScope::MismatchError) do |error|
          expect(error.message).not_to include('company-1', 'company-2')
        end
    end

    it 'accepts legacy provider responses without an organization field' do
      allow(configuration).to receive(:organization_id).and_return('company-1')
      stub_request(:get, "#{described_class::BASE_URL}/doctor/v1/patient/patient-1")
        .to_return(
          status: 200,
          body: { 'PROFILE_CODE' => 'patient-1' }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      expect(client.get_patient(patient_code: 'patient-1')).to include('PROFILE_CODE' => 'patient-1')
    end
  end

  describe 'write ambiguity' do
    it 'marks transport failures as ambiguous and retryable' do
      stub_request(:post, "#{described_class::BASE_URL}/v1/doctor/reception")
        .to_raise(Errno::ECONNRESET)

      expect { client.create_reception(params: { patient_code: 'patient-1' }) }
        .to raise_error(Integrations::Medelement::Client::ApiError) { |error|
          expect(error).to be_ambiguous
          expect(error).to be_retryable
          expect(error.message).not_to include('patient-1')
        }
    end

    it 'keeps provider validation failures non-ambiguous and non-retryable' do
      stub_request(:post, "#{described_class::BASE_URL}/v1/doctor/reception")
        .to_return(status: 422, body: '{"patient_phone":"sensitive"}')

      expect { client.create_reception(params: { patient_code: 'patient-1' }) }
        .to raise_error(Integrations::Medelement::Client::ApiError) { |error|
          expect(error).not_to be_ambiguous
          expect(error).not_to be_retryable
          expect(error.status).to eq(422)
          expect(error.message).not_to include('sensitive')
        }
    end
  end

  describe '#timetable' do
    it 'sends the documented two-boundary date array' do
      stub = stub_request(:get, "#{described_class::BASE_URL}/v1/timetable/get_timetable")
             .with(
               query: {
                 'date' => ['27.07.2026', '28.07.2026'],
                 'specialistCode' => 'specialist-1'
               }
             )
             .to_return(status: 200, body: '{}', headers: { 'Content-Type' => 'application/json' })

      client.timetable(
        specialist_code: 'specialist-1',
        starts_on: Date.new(2026, 7, 27),
        ends_on: Date.new(2026, 7, 28)
      )

      expect(stub).to have_been_requested.once
    end
  end
end
