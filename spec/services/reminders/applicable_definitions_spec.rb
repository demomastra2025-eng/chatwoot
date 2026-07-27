require 'rails_helper'

RSpec.describe Reminders::ApplicableDefinitions do
  describe '.call' do
    let(:appointment) { Scheduling::Appointment.new }
    let(:definitions) do
      [
        { entity_kind: 'appointment', body: 'Appointment only' },
        { entity_kind: 'deal', body: 'Deal only' },
        { body: 'Legacy shared step' }
      ]
    end

    it 'keeps matching and legacy definitions while excluding other entity kinds' do
      result = described_class.call(definitions: definitions, remindable: appointment)

      expect(result.pluck('body')).to eq(['Appointment only', 'Legacy shared step'])
    end

    it 'resolves every supported remindable class to its entity kind' do
      expect(described_class.entity_kind_for(Conversation.new)).to eq('conversation')
      expect(described_class.entity_kind_for(Crm::Deal.new)).to eq('deal')
      expect(described_class.entity_kind_for(Crm::Task.new)).to eq('task')
      expect(described_class.entity_kind_for(appointment)).to eq('appointment')
    end

    it 'rejects unsupported remindables' do
      expect do
        described_class.call(definitions: definitions, remindable: Contact.new)
      end.to raise_error(ArgumentError, 'Unsupported remindable: Contact')
    end
  end
end
