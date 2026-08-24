require 'rails_helper'

RSpec.describe Integrations::Medelement::OutboundChangeJob do
  include ActiveJob::TestHelper

  it 'retries an outbound change when another command owns the entity' do
    service = instance_double(Integrations::Medelement::OutboundChangeService)
    allow(Integrations::Medelement::OutboundChangeService).to receive(:new).and_return(service)
    allow(service).to receive(:perform).and_raise(
      Scheduling::Error.new(
        code: 'MEDELEMENT_COMMAND_IN_PROGRESS',
        message: 'busy',
        status: :conflict
      )
    )

    expect do
      described_class.perform_now(
        entity_type: 'contact',
        entity_id: 1,
        event_name: 'contact_updated',
        change: { changed_attributes: { 'name' => %w[Before After] } }
      )
    end.to have_enqueued_job(described_class).with(
      entity_type: 'contact',
      entity_id: 1,
      event_name: 'contact_updated',
      change: { changed_attributes: { 'name' => %w[Before After] } }
    )
  end

  it 'rejects a versioned payload without account binding' do
    expect do
      described_class.perform_now(
        entity_type: 'appointment',
        entity_id: 1,
        event_name: 'appointment_created',
        change: { payload_version: described_class::PAYLOAD_VERSION }
      )
    end.to raise_error(ArgumentError, 'Medelement outbound payload has invalid account binding')
  end

  it 'rejects partial, mixed, and unknown account binding shapes' do
    invalid_changes = [
      { account_id: 7 },
      { account_id: 7, payload_version: 1 },
      { account_id: 7, payload_version: described_class::PAYLOAD_VERSION + 1 },
      { account_id: nil, payload_version: described_class::PAYLOAD_VERSION },
      { account_id: 7, payload_version: nil },
      { account_id: 7, payload_version: 2.0 },
      { account_id: 7, payload_version: '2' },
      { account_id: 7, payload_version: '2junk' },
      { account_id: 7.0, payload_version: described_class::PAYLOAD_VERSION },
      { account_id: '7', payload_version: described_class::PAYLOAD_VERSION },
      { account_id: 0, payload_version: described_class::PAYLOAD_VERSION }
    ]

    invalid_changes.each do |change|
      expect do
        described_class.perform_now(
          entity_type: 'appointment',
          entity_id: 1,
          event_name: 'appointment_created',
          change: change
        )
      end.to raise_error(ArgumentError, 'Medelement outbound payload has invalid account binding')
    end
  end

  it 'accepts an exact legacy payload without account metadata' do
    change = { changed_attributes: { 'name' => %w[Before After] } }
    service = instance_double(Integrations::Medelement::OutboundChangeService, perform: true)
    expect(Integrations::Medelement::OutboundChangeService).to receive(:new).with(
      entity_type: 'contact',
      entity_id: 11,
      event_name: 'contact_updated',
      change: change,
      account_id: nil,
      actor_id: 3,
      event_key: 'legacy-event'
    ).and_return(service)

    described_class.perform_now(
      entity_type: 'contact',
      entity_id: 11,
      event_name: 'contact_updated',
      change: change,
      actor_id: 3,
      event_key: 'legacy-event'
    )
  end

  it 'passes the bound account to the outbound service' do
    service = instance_double(Integrations::Medelement::OutboundChangeService, perform: true)
    expect(Integrations::Medelement::OutboundChangeService).to receive(:new).with(
      entity_type: 'appointment',
      entity_id: 11,
      event_name: 'appointment_created',
      change: {},
      account_id: 7,
      actor_id: nil,
      event_key: nil
    ).and_return(service)

    described_class.perform_now(
      entity_type: 'appointment',
      entity_id: 11,
      event_name: 'appointment_created',
      change: { account_id: 7, payload_version: described_class::PAYLOAD_VERSION }
    )
  end

  it 'keeps its keyword shape compatible with the legacy worker' do
    expect(described_class.instance_method(:perform).parameters).to eq(
      [
        [:keyreq, :entity_type],
        [:keyreq, :entity_id],
        [:keyreq, :event_name],
        [:key, :change],
        [:key, :actor_id],
        [:key, :event_key]
      ]
    )
  end
end
