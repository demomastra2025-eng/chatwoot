require 'rails_helper'

RSpec.describe Integrations::Medelement::ProviderScope do
  describe '.validate_patient!' do
    let(:organization_id) { 'company-1' }
    let(:patient) do
      {
        'PROFILE_CODE' => 'patient-1',
        'IIN' => '940720300129',
        'PATIENT_PHONE_2' => '+77001234567'
      }
    end

    it 'accepts a patient with an explicit matching organization' do
      scoped_patient = patient.merge('COMPANY_CODE' => organization_id)

      expect(
        described_class.validate_patient!(scoped_patient, organization_id: organization_id)
      ).to eq(scoped_patient)
    end

    it 'rejects a patient with an explicit foreign organization' do
      expect do
        described_class.validate_patient!(patient.merge('COMPANY_CODE' => 'company-2'), organization_id: organization_id)
      end.to raise_error(described_class::MismatchError)
    end

    it 'rejects a mismatched expected patient code even for the configured organization' do
      expect do
        described_class.validate_patient!(
          patient.merge('COMPANY_CODE' => organization_id),
          organization_id: organization_id,
          expected_patient_code: 'patient-2'
        )
      end.to raise_error(described_class::MismatchError, 'Medelement patient reference cannot be verified')
    end

    it 'accepts a legacy unmarked patient only with an exact expected IIN' do
      expect(
        described_class.validate_patient!(
          patient,
          organization_id: organization_id,
          expected_iin: '940720300129'
        )
      ).to eq(patient)
    end

    it 'accepts a legacy unmarked patient only with an exact expected phone and patient code' do
      expect(
        described_class.validate_patient!(
          patient.except('IIN'),
          organization_id: organization_id,
          expected_patient_code: 'patient-1',
          expected_phone_numbers: ['+77001234567']
        )
      ).to eq(patient.except('IIN'))
    end

    it 'accepts an exact previously linked patient reference before evaluating a changed phone' do
      expect(
        described_class.validate_patient!(
          patient,
          organization_id: organization_id,
          expected_patient_code: 'patient-1',
          expected_iin: '940720300129',
          expected_phone_numbers: ['+770****9999']
        )
      ).to eq(patient)
    end

    it 'rejects a linked patient when the expected IIN differs' do
      expect do
        described_class.validate_patient!(
          patient,
          organization_id: organization_id,
          expected_patient_code: 'patient-1',
          expected_iin: '000000000000',
          expected_phone_numbers: ['+770****4567']
        )
      end.to raise_error(described_class::MismatchError, 'Medelement patient IIN cannot be verified')
    end

    it 'rejects a linked patient when the expected IIN is absent from the provider response' do
      expect do
        described_class.validate_patient!(
          patient.except('IIN'),
          organization_id: organization_id,
          expected_patient_code: 'patient-1',
          expected_iin: '940720300129',
          expected_phone_numbers: ['+770****4567']
        )
      end.to raise_error(described_class::MismatchError, 'Medelement patient IIN cannot be verified')
    end

    it 'rejects a legacy unmarked patient without a strong expected identity' do
      expect do
        described_class.validate_patient!(patient, organization_id: organization_id)
      end.to raise_error(described_class::MismatchError, 'Medelement patient organization cannot be verified')
    end

    it 'rejects a legacy unmarked patient when the expected patient code differs' do
      expect do
        described_class.validate_patient!(
          patient,
          organization_id: organization_id,
          expected_patient_code: 'patient-2',
          expected_iin: '940720300129'
        )
      end.to raise_error(described_class::MismatchError, 'Medelement patient reference cannot be verified')
    end
  end

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
