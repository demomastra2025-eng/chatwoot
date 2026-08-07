require 'rails_helper'

RSpec.describe Integrations::Medelement::ProviderCommands::RequestSnapshotBuilder do
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
