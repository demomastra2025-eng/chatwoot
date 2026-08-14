require 'rails_helper'

RSpec.describe Integrations::Medelement::ProviderScope do
  describe '.validate!' do
    it 'fails closed when the provider organization is not configured' do
      expect { described_class.validate!({}, organization_id: nil) }
        .to raise_error(described_class::MismatchError, 'Medelement organization is not configured')
    end

    it 'accepts nested company-code aliases for the configured organization' do
      payload = {
        'patient' => { 'company_code' => 'company-1' },
        'receptions' => [{ 'companyCode' => 'company-1' }]
      }

      expect(described_class.validate!(payload, organization_id: 'company-1')).to equal(payload)
    end

    it 'rejects a nested provider organization mismatch' do
      payload = { 'receptions' => [{ 'COMPANY_CODE' => 'company-2' }] }

      expect { described_class.validate!(payload, organization_id: 'company-1') }
        .to raise_error(described_class::MismatchError)
    end

    it 'keeps legacy read responses without a company code compatible' do
      payload = { 'PROFILE_CODE' => 'patient-1' }

      expect(described_class.validate!(payload, organization_id: 'company-1')).to equal(payload)
    end
  end

  describe '.validate_write!' do
    it 'fails closed when the provider organization is not configured' do
      expect { described_class.validate_write!({ 'company_code' => 'company-1' }, organization_id: nil) }
        .to raise_error(described_class::MismatchError, 'Medelement organization is not configured')
    end

    it 'requires the immutable write organization to match current configuration' do
      payload = { 'company_code' => 'company-1' }

      expect { described_class.validate_write!(payload, organization_id: 'company-2') }
        .to raise_error(described_class::MismatchError)
    end
  end
end
