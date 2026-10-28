require 'rails_helper'

RSpec.describe Captain::Tools::Operations::AppointmentOperations, type: :model do
  include ActiveSupport::Testing::TimeHelpers

  around { |example| travel_to(Time.utc(2026, 4, 19, 12)) { example.run } }

  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:resource) { create(:scheduling_resource, account: account, timezone: 'Asia/Almaty', slot_duration_min: 30) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let(:booking) { { resource_id: resource.id, starts_at: '2026-04-20T09:00:00+05:00', duration_min: 30 } }

  before do
    account.enable_features!('scheduling')
    create(:scheduling_work_rule, resource: resource, weekday: 1, start_minute: 9 * 60, end_minute: 18 * 60)
    service = create(:scheduling_service, account: account, duration_min: 30)
    create(:scheduling_service_price, account: account, service: service, resource: resource, active: true, price: 20_000)
  end

  def operations_for(actor)
    described_class.new(assistant: assistant, conversation: conversation, actor: actor)
  end

  describe 'a booking of the agent' do
    let(:operations) { operations_for(assistant) }

    it 'takes the one service of the specialist when the call names none' do
      appointment = operations.create_appointment(**booking)

      expect(appointment.service_id).to eq(account.scheduling_services.first.id)
      expect(operations.already_booked_appointment).to be_nil
    end

    it 'books to the specialist without a service when several are offered' do
      second = create(:scheduling_service, account: account, duration_min: 30)
      create(:scheduling_service_price, account: account, service: second, resource: resource, active: true, price: 10_000)

      expect(operations.create_appointment(**booking).service_id).to be_nil
    end

    it 'drops an unmapped MedElement service and keeps its name in the comment' do
      resource.update!(custom_attributes: { medelement_specialist_code: 'doctor-1',
                                            medelement_cabinets: [{ companyCabinetCode: 'cabinet-1' }] })
      contact.update!(name: 'Ada', last_name: 'Test', phone_number: '+77000000001')
      stub_provider_availability
      service = account.scheduling_services.first

      appointment = operations.create_appointment(**booking, service_id: service.id)

      expect(appointment).to have_attributes(resource_id: resource.id, service_id: nil)
      expect(appointment.client_comment).to include(service.name)
    end

    it 'keeps a mapped MedElement service with a positive price' do
      resource.update!(custom_attributes: { medelement_specialist_code: 'doctor-1',
                                            medelement_cabinets: [{ companyCabinetCode: 'cabinet-1' }] })
      contact.update!(name: 'Ada', last_name: 'Test', phone_number: '+77000000001')
      stub_provider_availability
      service = account.scheduling_services.first
      service.update!(custom_attributes: { medelement_nomenclature_code: 'service-1' })

      expect(operations.create_appointment(**booking, service_id: service.id).service_id).to eq(service.id)
    end

    it 'books with a named service and without one when the account has no service-price links' do
      Scheduling::ServicePrice.where(account_id: account.id).delete_all
      service = account.scheduling_services.first

      expect(operations.create_appointment(**booking).service_id).to be_nil

      with_service = operations.create_appointment(**booking, starts_at: '2026-04-20T10:00:00+05:00', service_id: service.id)
      expect(with_service).to have_attributes(service_id: service.id, service_amount: service.base_price)
    end

    it 'reports the appointment it found instead of booking again, and forgets it on the next booking' do
      first = operations.create_appointment(**booking)

      expect(operations.create_appointment(**booking)).to eq(first)
      expect(operations.already_booked_appointment).to eq(first)

      later = operations.create_appointment(**booking, starts_at: '2026-04-20T10:00:00+05:00')

      expect(later).not_to eq(first)
      expect(operations.already_booked_appointment).to be_nil
    end

    it 'does not report the appointment of another service at the same start as the same booking' do
      first_service = account.scheduling_services.first
      second_service = create(:scheduling_service, account: account, duration_min: 30)
      create(:scheduling_service_price, account: account, service: second_service, resource: resource, active: true, price: 10_000)
      first = operations.create_appointment(**booking, service_id: first_service.id)

      expect { operations.create_appointment(**booking, service_id: second_service.id) }.to raise_error(Scheduling::Error) { |error|
        expect(Captain::Tools::Agent::AppointmentResult::CONFLICT_CODES).to include(error.code)
      }
      expect(operations.already_booked_appointment).to be_nil

      expect(operations.create_appointment(**booking, service_id: first_service.id)).to eq(first)
      expect(operations.already_booked_appointment).to eq(first)
    end
  end

  def stub_provider_availability
    result = Integrations::Medelement::ResourceAvailabilityService::Result.new(
      status: 'fresh', checked_at: Time.current, slots: [{ medelement_cabinet_code: 'cabinet-1' }], reason: nil
    )
    service = instance_double(Integrations::Medelement::ResourceAvailabilityService, perform: result)
    allow(Integrations::Medelement::ResourceAvailabilityService).to receive(:new).and_return(service)
  end

  describe 'a booking of staff' do
    let(:user) { create(:user, account: account, role: :administrator) }
    let(:operations) { operations_for(user) }

    it 'leaves the service to the staff member: none is chosen for them' do
      appointment = operations.create_appointment(**booking)

      expect(appointment.service_id).to be_nil
    end

    it 'removes an unconfirmed service from an existing MedElement booking' do
      resource.update!(custom_attributes: { medelement_specialist_code: 'doctor-1',
                                            medelement_cabinets: [{ companyCabinetCode: 'cabinet-1' }] })
      contact.update!(name: 'Ada', last_name: 'Test', phone_number: '+77000000001')
      stub_provider_availability
      mapped = account.scheduling_services.first
      mapped.update!(custom_attributes: { medelement_nomenclature_code: 'service-1' })
      appointment = operations.create_appointment(**booking, service_id: mapped.id)
      unmapped = create(:scheduling_service, account: account, name: 'Additional visit', base_price: 10_000)

      updated = operations.update_current_appointment(appointment_id: appointment.id, service_id: unmapped.id)

      expect(updated.reload).to have_attributes(resource_id: resource.id, service_id: nil)
      expect(updated.client_comment).to include(unmapped.name)
    end

    it 'drops an existing unmapped service when moving a booking to a MedElement specialist without passing service_id' do
      contact.update!(name: 'Ada', last_name: 'Test', phone_number: '+77000000001')
      stub_provider_availability
      unmapped = account.scheduling_services.first
      appointment = operations.create_appointment(**booking, service_id: unmapped.id)
      medelement_doctor = create(
        :scheduling_resource,
        account: account,
        custom_attributes: {
          medelement_specialist_code: 'doctor-2',
          medelement_cabinets: [{ companyCabinetCode: 'cabinet-1' }]
        }
      )

      updated = operations.update_current_appointment(
        appointment_id: appointment.id,
        resource_id: medelement_doctor.id,
        custom_attributes: { medelement_cabinet_code: 'cabinet-1' }
      )

      expect(updated.reload).to have_attributes(resource_id: medelement_doctor.id, service_id: nil)
      expect(updated.client_comment).to include(unmapped.name)
    end

    it 'keeps the taken-slot error of a repeated booking: staff see the conflict, not an answer of the agent' do
      operations.create_appointment(**booking)

      expect { operations.create_appointment(**booking) }.to raise_error(Scheduling::Error) { |error|
        expect(Captain::Tools::Agent::AppointmentResult::CONFLICT_CODES).to include(error.code)
      }
      expect(operations.already_booked_appointment).to be_nil
    end
  end
end
