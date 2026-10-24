require 'rails_helper'

describe Dispatcher do
  subject(:dispatcher) { described_class.instance }

  let(:timestamp) { Time.zone.now }
  let(:data) { { appointment: instance_double(Scheduling::Appointment) } }

  before do
    allow(dispatcher.sync_dispatcher).to receive(:dispatch)
    allow(dispatcher.async_dispatcher).to receive(:dispatch)
  end

  it 'hands every event to the sync and async dispatchers' do
    dispatcher.dispatch(Events::Types::APPOINTMENT_UPDATED, timestamp, data)

    expect(dispatcher.sync_dispatcher).to have_received(:dispatch).with(Events::Types::APPOINTMENT_UPDATED, timestamp, data)
    expect(dispatcher.async_dispatcher).to have_received(:dispatch).with(Events::Types::APPOINTMENT_UPDATED, timestamp, data)
  end

  describe 'inside a MedElement reconciliation' do
    it 'holds back every appointment event, for both dispatchers' do
      [Events::Types::APPOINTMENT_UPDATED, Events::Types::APPOINTMENT_COMPLETED, Events::Types::APPOINTMENT_CANCELLED,
       Events::Types::APPOINTMENT_CREATED].each do |event_name|
        Current.with_medelement_reconciliation { dispatcher.dispatch(event_name, timestamp, data) }
      end

      expect(dispatcher.sync_dispatcher).not_to have_received(:dispatch)
      expect(dispatcher.async_dispatcher).not_to have_received(:dispatch)
    end

    it 'does not touch events of anything else' do
      Current.with_medelement_reconciliation { dispatcher.dispatch(Events::Types::CONTACT_UPDATED, timestamp, data) }

      expect(dispatcher.async_dispatcher).to have_received(:dispatch).with(Events::Types::CONTACT_UPDATED, timestamp, data)
    end

    it 'dispatches appointment events again as soon as the block is left' do
      Current.with_medelement_reconciliation { nil }
      dispatcher.dispatch(Events::Types::APPOINTMENT_COMPLETED, timestamp, data)

      expect(dispatcher.async_dispatcher).to have_received(:dispatch).with(Events::Types::APPOINTMENT_COMPLETED, timestamp, data)
    end
  end
end
