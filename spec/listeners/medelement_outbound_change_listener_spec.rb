require 'rails_helper'

RSpec.describe MedelementOutboundChangeListener do
  include ActiveJob::TestHelper

  let(:listener) { described_class.instance }
  let(:account) { create(:account) }
  let(:actor) { create(:user) }
  let(:resource) { create(:scheduling_resource, account: account) }
  let(:appointment) { create(:scheduling_appointment, account: account, resource: resource) }

  before { clear_enqueued_jobs }

  it 'enqueues local appointment changes immediately with the desired state' do
    event = Events::Base.new(
      'appointment_updated',
      Time.current,
      appointment: appointment,
      performed_by: actor,
      changed_attributes: {
        'starts_at' => [appointment.starts_at, appointment.starts_at + 1.hour],
        'ends_at' => [appointment.ends_at, appointment.ends_at + 1.hour]
      }
    )

    listener.appointment_updated(event)

    expect(Integrations::Medelement::OutboundChangeJob).to have_been_enqueued.with(
      entity_type: 'appointment',
      entity_id: appointment.id,
      event_name: 'appointment_updated',
      change: {
        account_id: account.id,
        payload_version: 2,
        changed_attributes: event.data[:changed_attributes],
        desired_attributes: hash_including(
          'starts_at' => appointment.starts_at,
          'ends_at' => appointment.ends_at,
          Integrations::Medelement::OutboundChangeService::CONTACT_SNAPSHOT_KEY => anything
        )
      },
      actor_id: actor.id,
      event_key: a_string_starting_with('onelink-event:')
    )
  end

  it 'ignores provider-imported appointment changes without a OneLink actor' do
    event = Events::Base.new(
      'appointment_updated',
      Time.current,
      appointment: appointment,
      performed_by: nil,
      changed_attributes: { 'starts_at' => [appointment.starts_at, appointment.starts_at + 1.hour] }
    )

    listener.appointment_updated(event)

    expect(Integrations::Medelement::OutboundChangeJob).not_to have_been_enqueued
  end

  it 'enqueues Captain appointment changes without assigning an assistant id as a user id' do
    assistant = create(:captain_assistant, account: account)
    event = Events::Base.new(
      'appointment_created',
      Time.current,
      appointment: appointment,
      performed_by: assistant
    )

    listener.appointment_created(event)

    expect(Integrations::Medelement::OutboundChangeJob).to have_been_enqueued.with(
      entity_type: 'appointment',
      entity_id: appointment.id,
      event_name: 'appointment_created',
      change: {
        account_id: account.id,
        payload_version: 2,
        changed_attributes: {},
        desired_attributes: hash_including(
          Integrations::Medelement::OutboundChangeService::CONTACT_SNAPSHOT_KEY => anything
        )
      },
      actor_id: nil,
      event_key: a_string_starting_with('onelink-event:')
    )
  end

  it 'ignores a Captain assistant from another account' do
    assistant = create(:captain_assistant, account: create(:account))
    event = Events::Base.new('appointment_created', Time.current, appointment: appointment, performed_by: assistant)

    listener.appointment_created(event)

    expect(Integrations::Medelement::OutboundChangeJob).not_to have_been_enqueued
  end

  it 'enqueues actor-backed patient updates and ignores unaudited changes' do
    linked_contact = create(
      :contact,
      account: account,
      custom_attributes: { 'medelement_patient_code' => 'patient-1' }
    )
    unlinked_contact = create(:contact, account: account)

    listener.contact_updated(
      Events::Base.new(
        'contact_updated',
        Time.current,
        contact: linked_contact,
        performed_by: actor,
        changed_attributes: { 'name' => %w[Before After] }
      )
    )
    listener.contact_updated(
      Events::Base.new(
        'contact_updated',
        Time.current,
        contact: unlinked_contact,
        performed_by: nil,
        changed_attributes: { 'name' => %w[Before After] }
      )
    )

    expect(Integrations::Medelement::OutboundChangeJob).to have_been_enqueued.once.with(
      entity_type: 'contact',
      entity_id: linked_contact.id,
      event_name: 'contact_updated',
      change: {
        account_id: account.id,
        payload_version: 2,
        changed_attributes: { 'name' => %w[Before After] },
        desired_attributes: linked_contact.attributes.slice(*Integrations::Medelement::OutboundChangeService::CONTACT_UPDATE_KEYS)
      },
      actor_id: actor.id,
      event_key: a_string_starting_with('onelink-event:')
    )
  end

  it 'enqueues an actor-backed scheduling patient creation with a full desired identity snapshot' do
    contact = create(:contact, account: account, name: 'Ivan', last_name: 'Ivanov')
    event = Events::Base.new('contact.created', Time.current, contact: contact, performed_by: actor)

    listener.contact_created(event)

    expect(Integrations::Medelement::OutboundChangeJob).to have_been_enqueued.with(
      entity_type: 'contact',
      entity_id: contact.id,
      event_name: 'contact.created',
      change: {
        account_id: account.id,
        payload_version: 2,
        changed_attributes: {},
        desired_attributes: contact.attributes.slice(*Integrations::Medelement::OutboundChangeService::CONTACT_UPDATE_KEYS)
      },
      actor_id: actor.id,
      event_key: a_string_starting_with('onelink-event:')
    )
  end

  it 'freezes the complete appointment and contact state in the queued event' do
    appointment.update!(
      client_first_name: 'Event',
      client_last_name: 'Patient',
      client_phone: '+770****0001',
      custom_attributes: { 'medelement_cabinet_code' => 'cabinet-1' }
    )
    appointment.contact.update!(
      name: 'Event',
      last_name: 'Patient',
      phone_number: ['+7', '701', '123', '4567'].join,
      custom_attributes: { 'medelement_patient_code' => 'patient-1', 'secondary_phones' => [['+7', '702', '123', '4567'].join] }
    )
    event = Events::Base.new('appointment_created', Time.current, appointment: appointment, performed_by: actor)

    listener.appointment_created(event)

    expect(Integrations::Medelement::OutboundChangeJob).to have_been_enqueued.with(
      entity_type: 'appointment',
      entity_id: appointment.id,
      event_name: 'appointment_created',
      change: {
        account_id: account.id,
        payload_version: 2,
        changed_attributes: {},
        desired_attributes: hash_including(
          'client_first_name' => 'Event',
          'client_last_name' => 'Patient',
          'client_phone' => '+770****0001',
          Integrations::Medelement::OutboundChangeService::CONTACT_SNAPSHOT_KEY => hash_including(
            'name' => 'Event',
            'last_name' => 'Patient',
            'phone_number' => ['+7', '701', '123', '4567'].join,
            'custom_attributes' => hash_including('secondary_phones' => [['+7', '702', '123', '4567'].join])
          )
        )
      },
      actor_id: actor.id,
      event_key: a_string_starting_with('onelink-event:')
    )
  end
end
