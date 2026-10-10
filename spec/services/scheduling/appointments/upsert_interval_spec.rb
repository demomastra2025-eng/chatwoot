require 'rails_helper'

RSpec.describe Scheduling::Appointments::UpsertService do
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
  let(:resource) do
    create(:scheduling_resource, account: account, timezone: 'America/New_York', custom_attributes: {
      'medelement_specialist_code' => 'doctor-1', 'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }]
    })
  end
  let(:service) do
    create(:scheduling_service, account: account, duration_min: 30, base_price: 20_000,
                                custom_attributes: { 'medelement_nomenclature_code' => 'service-1' })
  end
  let(:zone) { ActiveSupport::TimeZone['Asia/Almaty'] }
  let(:starts_at) { zone.local(2026, 4, 20, 9) }
  let(:client) { instance_double(Integrations::Medelement::Client, get_receptions: []) }
  let(:params) do
    { resource_id: resource.id, contact_id: owner.id, patient_contact_id: patient.id,
      service_id: service.id, starts_at: starts_at.iso8601, ends_at: (starts_at + 75.minutes).iso8601,
      custom_attributes: { medelement_cabinet_code: 'cabinet-1' } }
  end

  before do
    account.enable_features!('scheduling')
    create(:integrations_hook, :medelement, account: account)
    create(:scheduling_service_price, account: account, resource: resource, service: service)
    allow(Integrations::Medelement::Client).to receive(:new).and_return(client)
    allow(client).to receive(:timetable) { provider_timetable }
  end

  def provider_timetable
    date = starts_at.strftime('%d.%m.%Y')
    { date => { 'timetable' => [{ 'start' => "#{date} 09:00", 'end' => "#{date} 12:00", 'working' => true }] } }
  end

  def perform(overrides = {})
    described_class.new(account: account, actor: actor, params: params.merge(overrides)).perform
  end

  it 'reads provider evidence before entering the mutation transaction and selects the exact patient inside it' do
    # Fixture transactions alone cannot detect a misplaced clinical selection.
    mutation_depth = 0
    allow(ApplicationRecord).to receive(:transaction).and_wrap_original do |original, *args, **options, &block|
      original.call(*args, **options) do
        mutation_depth += 1
        begin
          block.call
        ensure
          mutation_depth -= 1
        end
      end
    end
    allow(client).to receive(:timetable) do
      expect(mutation_depth).to eq(0)
      expect(patient.reload.custom_attributes).not_to have_key(Contacts::SharedPhone::SHARED_OWNER_KEY)
      provider_timetable
    end
    expect(Contacts::PhoneIdentityLock).to receive(:acquire!).at_least(:once).and_wrap_original do |original, **options|
      expect(mutation_depth).to be_positive
      original.call(**options)
    end

    appointment = perform

    expect(appointment).to have_attributes(contact_id: owner.id, patient_contact_id: patient.id,
                                           duration_min: 75, starts_at: starts_at, ends_at: starts_at + 75.minutes)
    expect(appointment.service_duration_min_snapshot).to eq(30)
    expect(owner.reload).to have_attributes(name: 'Mother', phone_number: '+77000000009')
  end

  it 'rolls back clinical binding when a local appointment occupies the manually extended tail' do
    create(:scheduling_appointment, account: account, resource: resource,
                                    starts_at: starts_at + 1.hour, ends_at: starts_at + 90.minutes)
    original = patient.reload.attributes
    original_count = account.scheduling_appointments.count

    expect { perform }.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('APPOINTMENT_SLOT_UNAVAILABLE') }

    expect(account.scheduling_appointments.count).to eq(original_count)
    expect(patient.reload.attributes.except('updated_at')).to eq(original.except('updated_at'))
    expect(owner.reload.phone_number).to eq('+77000000009')
  end

  it 'never binds a patient or creates a local visit when provider evidence is unavailable' do
    allow(client).to receive(:timetable).and_raise(Integrations::Medelement::Client::ApiError.new('timeout', status: 504))
    expect(Contacts::PhoneIdentityLock).not_to receive(:acquire!)

    expect { perform }.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_AVAILABILITY_UNVERIFIED') }
    expect(account.scheduling_appointments).to be_empty
  end

  it 'preserves the authored duration on a later note edit without another provider read' do
    appointment = perform
    expect(client).not_to receive(:timetable)

    described_class.new(account: account, actor: actor, appointment: appointment,
                        params: { client_comment: 'Updated note' }).perform

    expect(appointment.reload).to have_attributes(duration_min: 75, ends_at: starts_at + 75.minutes,
                                                 client_comment: 'Updated note')
  end

  [Date.new(2026, 4, 18), Date.new(2026, 7, 19)].each do |date|
    context "when staff requests #{date}" do
      let(:starts_at) { zone.local(date.year, date.month, date.day, 9) }

      it 'keeps the existing date permissions and still requires a confirmed free provider interval' do
        expect(perform).to have_attributes(starts_at: starts_at, duration_min: 75)
        expect(client).to have_received(:timetable).with(specialist_code: 'doctor-1', starts_on: date, ends_on: date)
      end
    end
  end
end
