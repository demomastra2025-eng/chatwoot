require 'rails_helper'

RSpec.describe Integrations::Medelement::ProviderCommands::RequestSnapshotBuilder do
  describe '#build' do
    it 'uses structured appointment names in the MedElement patient payload' do
      account = create(:account)
      contact = create(
        :contact,
        account: account,
        phone_number: '+77000000001',
        custom_attributes: { 'medelement_iin' => '940720300129' }
      )
      appointment = create(
        :scheduling_appointment,
        account: account,
        contact: contact,
        client_first_name: 'Айжан',
        client_last_name: 'Касымова',
        client_middle_name: 'Ерлановна',
        client_name: 'Айжан Касымова Ерлановна'
      )
      hook = build_stubbed(:integrations_hook, account: account, app_id: 'medelement', settings: {})

      snapshot = described_class.new(
        account: account,
        hook: hook,
        operation: 'create_patient',
        appointment: appointment,
        contact: contact
      ).build

      expect(snapshot.dig('patient', 'payload')).to include(
        'name' => 'Айжан',
        'lastname' => 'Касымова',
        'middlename' => 'Ерлановна',
        'iin' => '940720300129'
      )
    end

    it 'validates contact IIN fallbacks for structured appointments' do
      account = create(:account)
      contact = create(
        :contact,
        account: account,
        identifier: '940720300129',
        phone_number: '+77000000001',
        custom_attributes: { 'medelement_iin' => 'invalid-iin' }
      )
      appointment = create(
        :scheduling_appointment,
        account: account,
        contact: contact,
        client_first_name: 'Айжан',
        client_last_name: 'Касымова',
        client_name: 'Айжан Касымова'
      )
      hook = build_stubbed(:integrations_hook, account: account, app_id: 'medelement', settings: {})

      snapshot = described_class.new(
        account: account,
        hook: hook,
        operation: 'create_patient',
        appointment: appointment,
        contact: contact
      ).build

      expect(snapshot.dig('patient', 'payload', 'iin')).to eq('940720300129')
    end

    it 'keeps using contact identity for legacy appointments without structured names' do
      account = create(:account)
      contact = create(
        :contact,
        account: account,
        name: 'Айжан',
        last_name: 'Касымова',
        middle_name: 'Ерлановна',
        phone_number: '+77000000001'
      )
      appointment = create(
        :scheduling_appointment,
        account: account,
        contact: contact,
        client_first_name: nil,
        client_last_name: nil,
        client_middle_name: nil,
        client_name: 'legacy display name'
      )
      hook = build_stubbed(:integrations_hook, account: account, app_id: 'medelement', settings: {})

      snapshot = described_class.new(
        account: account,
        hook: hook,
        operation: 'create_patient',
        appointment: appointment,
        contact: contact
      ).build

      expect(snapshot.dig('patient', 'payload')).to include(
        'name' => 'Айжан',
        'lastname' => 'Касымова',
        'middlename' => 'Ерлановна'
      )
    end

    it 'freezes the configured provider organization in the patient payload' do
      account = create(:account)
      contact = create(
        :contact,
        account: account,
        name: 'Айжан',
        last_name: 'Касымова',
        middle_name: 'Ерлановна',
        phone_number: '+77015550001'
      )
      hook = build_stubbed(
        :integrations_hook,
        account: account,
        app_id: 'medelement',
        settings: { 'organization_id' => 'company-1' }
      )

      snapshot = described_class.new(
        account: account,
        hook: hook,
        operation: 'create_patient',
        contact: contact
      ).build

      expect(snapshot['organization_id']).to eq('company-1')
      expect(snapshot.dig('patient', 'payload', 'company_code')).to eq('company-1')
    end

    it 'uses desired contact values captured by the source event' do
      account = create(:account)
      contact = create(
        :contact,
        account: account,
        name: 'Later',
        last_name: 'Patient',
        email: 'later@example.com',
        phone_number: '+77011234567',
        custom_attributes: { 'medelement_patient_code' => 'patient-1' }
      )
      hook = build_stubbed(
        :integrations_hook,
        account: account,
        app_id: 'medelement',
        settings: { 'organization_id' => 'company-1' }
      )

      snapshot = described_class.new(
        account: account,
        hook: hook,
        operation: 'update_patient',
        contact: contact,
        desired_attributes: {
          name: 'Event',
          email: 'event@example.com',
          phone_number: '+77017654321'
        }
      ).build

      expect(snapshot.dig('patient', 'payload')).to include(
        'name' => 'Event',
        'patient_email' => 'event@example.com'
      )
      expect(snapshot.dig('patient', 'phone_number')).to eq('+77017654321')
      expect(snapshot.dig('patient', 'phone_numbers')).to eq(['+77017654321'])
    end
  end

  describe '.service_codes' do
    it 'reads the exact legacy v1 singular shape for old-web to new-worker rollout' do
      snapshot = {
        'version' => 1,
        'reception' => { 'nomenclature_code' => 'legacy-service' }
      }

      expect(described_class.service_codes(snapshot)).to eq(['legacy-service'])
      expect(described_class.valid_schema?(snapshot)).to be(true)
    end

    it 'reads the exact v2 plural shape' do
      snapshot = {
        'version' => 2,
        'reception' => { 'nomenclature_codes' => %w[service-1 service-2 service-1] }
      }

      expect(described_class.service_codes(snapshot)).to eq(%w[service-1 service-2])
      expect(described_class.valid_schema?(snapshot)).to be(true)
    end

    it 'accepts a v2 legacy alias only when it matches the first plural code' do
      snapshot = {
        'version' => 2,
        'reception' => {
          'nomenclature_code' => 'service-1',
          'nomenclature_codes' => %w[service-1 service-2]
        }
      }

      expect(described_class.service_codes(snapshot)).to eq(%w[service-1 service-2])
      expect(described_class.valid_schema?(snapshot)).to be(true)

      snapshot['reception']['nomenclature_code'] = 'other-service'
      expect(described_class.valid_schema?(snapshot)).to be(false)
    end

    it 'rejects a mixed v1 shape' do
      snapshot = {
        'version' => 1,
        'reception' => { 'nomenclature_code' => 'service-1', 'nomenclature_codes' => ['service-1'] }
      }

      expect(described_class.valid_schema?(snapshot)).to be(false)
      expect { described_class.service_codes(snapshot) }.to raise_error(described_class::SnapshotSchemaError)
    end

    it 'rejects a partial v2 shape without the plural field' do
      snapshot = { 'version' => 2, 'reception' => {} }

      expect(described_class.valid_schema?(snapshot)).to be(false)
    end

    it 'rejects unsupported versions even without a reception payload' do
      expect(described_class.valid_schema?('version' => 3)).to be(false)
      expect(described_class.valid_schema?({})).to be(false)
    end

    it 'accepts normalized immutable patient phone numbers' do
      primary_phone = ['+7', '701', '123', '4567'].join
      secondary_phone = ['+7', '777', '111', '2233'].join
      snapshot = {
        'version' => 2,
        'patient' => {
          'phone_number' => primary_phone,
          'phone_numbers' => [primary_phone, secondary_phone],
          'payload' => {}
        }
      }

      expect(described_class.valid_schema?(snapshot)).to be(true)
    end

    it 'rejects malformed patient phone number snapshots' do
      snapshot = {
        'version' => 2,
        'patient' => { 'phone_numbers' => ['8 (701) 123-45-67'] }
      }

      expect(described_class.valid_schema?(snapshot)).to be(false)
    end
  end
end
