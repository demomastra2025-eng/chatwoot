require 'rails_helper'

RSpec.describe Captain::Runtime::OperationTarget do
  let(:son) { { first_name: 'Test', last_name: 'Son', birth_date: '2016-11-11' } }

  describe 'a booking' do
    it 'has no target of its own for the person of the conversation' do
      expect(described_class.of('create_appointment', { resource_id: 1, starts_at: '2026-10-15T10:00' })).to be_nil
      expect(described_class.of('create_appointment', { resource_id: 1, patient: {} })).to be_nil
      expect(described_class.of('create_appointment', { patient: 'a child' })).to be_nil
    end

    it 'has the person named by the patient parameter as its target' do
      target = described_class.of('create_appointment', { patient: son })

      expect(target).to be_present
      expect(described_class.of('create_appointment', { patient: son.merge(last_name: 'Daughter') })).not_to eq(target)
      expect(described_class.of('create_appointment', { patient: son.merge(birth_date: '2018-03-03') })).not_to eq(target)
    end

    it 'is the same person whatever the key type, the case and the spaces, and with or without phone and gender' do
      target = described_class.of('create_appointment', { patient: son })

      expect(described_class.of('create_appointment', { 'patient' => son.stringify_keys })).to eq(target)
      expect(described_class.of('create_appointment', { patient: son.transform_values { |value| "  #{value.upcase}  " } })).to eq(target)
      expect(described_class.of('create_appointment', { patient: son.merge(phone: '+77010000000', gender: 'male') })).to eq(target)
    end

    it 'tells the tool of a connected server by its own name' do
      expect(described_class.of('clinic__create_appointment', { patient: son })).to eq(described_class.of('create_appointment', { patient: son }))
    end
  end

  describe 'a change or a cancellation' do
    it 'has the appointment as its target' do
      expect(described_class.of('update_appointment', { appointment_id: 101, starts_at: '2026-10-16T10:00' })).to eq('101')
      expect(described_class.of('cancel_appointment', { appointment_id: '102' })).to eq('102')
    end

    it 'has no target of its own for the current appointment of the conversation' do
      expect(described_class.of('update_appointment', { starts_at: '2026-10-16T10:00' })).to be_nil
      expect(described_class.of('cancel_appointment', {})).to be_nil
    end
  end

  it 'has no target for any other tool, and none for arguments it cannot read' do
    expect(described_class.of('create_task', { patient: son, appointment_id: 1 })).to be_nil
    expect(described_class.of('create_appointment', nil)).to be_nil
    expect(described_class.of(nil, { patient: son })).to be_nil
  end
end
