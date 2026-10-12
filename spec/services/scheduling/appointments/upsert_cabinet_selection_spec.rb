require 'rails_helper'

# A new MedElement reception without a cabinet gets the cabinet the provider shows free for the interval, so callers (the AI agent
# among them) never have to know cabinets: the only free one, or the first of several in cabinet-code order (the order slot search
# uses); none free means the time is taken.
RSpec.describe Scheduling::Appointments::UpsertService, 'cabinet selection' do
  include ActiveSupport::Testing::TimeHelpers

  around { |example| travel_to(Time.utc(2026, 4, 19, 20)) { example.run } }

  let(:account) { create(:account) }
  let(:actor) { create(:user, account: account) }
  let(:owner) { create(:contact, account: account, name: 'Mother', phone_number: '+77000000009') }
  let(:patient) do
    create(:contact, account: account, name: 'Test', last_name: 'Patient', phone_number: nil,
                     identifier: '940720300129', custom_attributes: {
                       Contacts::SharedPhone::CARD_KEY => true, 'iin' => '940720300129',
                       'medelement_first_name' => 'Test', 'medelement_last_name' => 'Patient'
                     })
  end
  let(:cabinets) { [{ 'companyCabinetCode' => 'cabinet-2' }, { 'companyCabinetCode' => 'cabinet-1' }] }
  let(:resource) do
    create(:scheduling_resource, account: account, timezone: 'America/New_York', custom_attributes: {
      'medelement_specialist_code' => 'doctor-1', 'medelement_cabinets' => cabinets
    })
  end
  let(:service) do
    create(:scheduling_service, account: account, duration_min: 30, base_price: 20_000,
                                custom_attributes: { 'medelement_nomenclature_code' => 'service-1' })
  end
  let(:zone) { ActiveSupport::TimeZone['Asia/Almaty'] }
  let(:starts_at) { zone.local(2026, 4, 20, 9) }
  let(:occupied_cabinets) { [] }
  let(:client) { instance_double(Integrations::Medelement::Client) }
  let(:params) do
    { resource_id: resource.id, contact_id: owner.id, patient_contact_id: patient.id,
      service_id: service.id, starts_at: starts_at.iso8601, ends_at: (starts_at + 30.minutes).iso8601 }
  end

  before do
    account.enable_features!('scheduling')
    create(:integrations_hook, :medelement, account: account)
    create(:scheduling_service_price, account: account, resource: resource, service: service)
    allow(Integrations::Medelement::Client).to receive(:new).and_return(client)
    allow(client).to receive(:timetable) { provider_timetable }
    allow(client).to receive(:get_receptions) do |**query|
      occupied_cabinets.include?(query[:company_cabinet_code]) ? [busy_reception] : []
    end
    # Finish contact factory callbacks before observing the booking boundary.
    params
  end

  def provider_timetable
    date = starts_at.strftime('%d.%m.%Y')
    { date => { 'timetable' => [{ 'start' => "#{date} 09:00", 'end' => "#{date} 12:00", 'working' => true }] } }
  end

  def busy_reception
    format = '%d.%m.%Y %H:%M:%S'
    { 'REMOVED' => 0, 'RECEPTION_CODE' => 'busy-1',
      'STARTTIME' => starts_at.strftime(format), 'ENDTIME' => (starts_at + 30.minutes).strftime(format) }
  end

  def perform(overrides = {})
    described_class.new(account: account, actor: actor, params: params.merge(overrides)).perform
  end

  context 'when the resource has one cabinet' do
    let(:cabinets) { [{ 'companyCabinetCode' => 'cabinet-1' }] }

    it 'uses it without being told' do
      expect(perform.reload.custom_attributes).to include('medelement_cabinet_code' => 'cabinet-1')
    end

    it 'treats a blank cabinet as none' do
      appointment = perform(custom_attributes: { medelement_cabinet_code: ' ' })

      expect(appointment.reload.custom_attributes).to include('medelement_cabinet_code' => 'cabinet-1')
    end
  end

  context 'when several cabinets are free' do
    it 'takes the first one in cabinet-code order, whatever order the specialist lists them in' do
      expect(perform.reload.custom_attributes).to include('medelement_cabinet_code' => 'cabinet-1')
    end

    it 'keeps a cabinet the caller chose' do
      appointment = perform(custom_attributes: { medelement_cabinet_code: 'cabinet-2' })

      expect(appointment.reload.custom_attributes).to include('medelement_cabinet_code' => 'cabinet-2')
    end
  end

  context 'when the first cabinet is occupied at that time' do
    let(:occupied_cabinets) { ['cabinet-1'] }

    it 'takes the free one' do
      expect(perform.reload.custom_attributes).to include('medelement_cabinet_code' => 'cabinet-2')
    end
  end

  context 'when every cabinet is occupied at that time' do
    let(:occupied_cabinets) { %w[cabinet-1 cabinet-2] }

    it 'fails as a taken time and writes nothing' do
      original = patient.reload.attributes

      expect { perform }.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('APPOINTMENT_SLOT_UNAVAILABLE') }

      expect(account.scheduling_appointments.reload).to be_empty
      expect(patient.reload.attributes.except('updated_at')).to eq(original.except('updated_at'))
    end

    it 'is a business failure the agent answers by offering another time' do
      error = begin
        perform
      rescue Scheduling::Error => e
        e
      end

      expect(Captain::Tools::Agent::AppointmentResult.failure(error)).to include(reason: 'time_taken', error_class: 'business')
    end
  end

  context 'when the appointment already exists' do
    it 'never adds a cabinet to it' do
      appointment = perform(custom_attributes: { medelement_cabinet_code: 'cabinet-1' })
      appointment.update!(custom_attributes: appointment.custom_attributes.except('medelement_cabinet_code'))

      described_class.new(account: account, actor: actor, appointment: appointment, params: { client_comment: 'Updated note' }).perform

      expect(appointment.reload).to have_attributes(client_comment: 'Updated note')
      expect(appointment.custom_attributes).not_to have_key('medelement_cabinet_code')
    end
  end
end
