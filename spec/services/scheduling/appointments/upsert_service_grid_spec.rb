require 'rails_helper'

# A booking for a MedElement specialist starts on the grid of the specialist's cells (see Scheduling::SlotGrid); staff in the
# calendar and the AI agent both book through this service, so an off-grid start is refused for both.
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
  let(:reception_time) { 30 }
  let(:grid_override) { nil }
  # The detector has settled the grid of the doctor (slot_grid_checked_at): only then is a start off it refused.
  let(:verified) { true }
  let(:resource) do
    attributes = { 'medelement_specialist_code' => 'doctor-1', 'medelement_reception_time' => reception_time,
                   'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }] }
    attributes['slot_grid_min'] = grid_override if grid_override
    attributes['slot_grid_checked_at'] = '2026-04-19T00:00:00Z' if verified
    create(:scheduling_resource, account: account, timezone: 'Asia/Almaty', slot_duration_min: reception_time, custom_attributes: attributes)
  end
  let(:service) do
    create(:scheduling_service, account: account, duration_min: 30, base_price: 20_000,
                                custom_attributes: { 'medelement_nomenclature_code' => 'service-1' })
  end
  let(:zone) { ActiveSupport::TimeZone['Asia/Almaty'] }
  let(:starts_at) { zone.local(2026, 4, 20, 9, 30) }
  let(:client) { instance_double(Integrations::Medelement::Client, get_receptions: []) }
  let(:params) do
    { resource_id: resource.id, contact_id: owner.id, patient_contact_id: patient.id,
      service_id: service.id, starts_at: starts_at.iso8601, ends_at: (starts_at + 30.minutes).iso8601,
      custom_attributes: { medelement_cabinet_code: 'cabinet-1' } }
  end

  before do
    account.enable_features!('scheduling')
    create(:integrations_hook, :medelement, account: account)
    create(:scheduling_service_price, account: account, resource: resource, service: service)
    allow(Integrations::Medelement::Client).to receive(:new).and_return(client)
    allow(client).to receive(:timetable) { provider_timetable }
    params
  end

  # The provider gives one working row per cell, from 09:00 to 12:00.
  def provider_timetable
    date = zone.local(2026, 4, 20).strftime('%d.%m.%Y')
    rows = ((9 * 60)...(12 * 60)).step(reception_time).map do |minute|
      { 'start' => "#{date} #{clock(minute)}", 'end' => "#{date} #{clock(minute + reception_time)}", 'working' => true }
    end
    { date => { 'timetable' => rows } }
  end

  def clock(minute)
    format('%<hour>02d:%<minute>02d', hour: minute / 60, minute: minute % 60)
  end

  def perform(overrides = {})
    described_class.new(account: account, actor: actor, params: params.merge(overrides)).perform
  end

  def move(booking, starts)
    described_class.new(account: account, actor: actor, appointment: booking,
                        params: { starts_at: starts.iso8601, ends_at: (starts + 30.minutes).iso8601 }).perform
  end

  def off_grid(starts)
    perform(starts_at: starts.iso8601, ends_at: (starts + 30.minutes).iso8601)
  end

  it 'books a start that is a cell start' do
    expect(perform).to have_attributes(starts_at: starts_at, duration_min: 30)
  end

  it 'refuses a start between two cell starts with the starts next to it and creates nothing' do
    expect { off_grid(zone.local(2026, 4, 20, 9, 15)) }.to raise_error(Scheduling::Error) { |error|
      expect(error.code).to eq('START_OFF_GRID')
      expect(error.status).to eq(422)
      expect(error.message).to include('09:15', '30 minutes', '09:00 or 09:30')
      expect(error.details).to include(step_min: 30)
    }
    expect(account.scheduling_appointments.reload).to be_empty
  end

  it 'refuses a start of five minutes past a cell start, as the old five-minute step produced' do
    expect { off_grid(zone.local(2026, 4, 20, 10, 5)) }.to raise_error(Scheduling::Error) { |error|
      expect(error.code).to eq('START_OFF_GRID')
    }
  end

  context 'with slot_grid_min 10 for a doctor booked on 10-minute boundaries inside the cells' do
    let(:grid_override) { 10 }

    it 'books a 10-minute start inside a cell' do
      expect(off_grid(zone.local(2026, 4, 20, 9, 10))).to have_attributes(starts_at: zone.local(2026, 4, 20, 9, 10))
    end

    it 'still refuses a start that is not on the finer grid' do
      expect { off_grid(zone.local(2026, 4, 20, 9, 15)) }.to raise_error(Scheduling::Error) { |error|
        expect(error.code).to eq('START_OFF_GRID')
      }
    end
  end

  context 'when the grid of the doctor is not verified yet' do
    let(:verified) { false }

    it 'books a start inside a cell, as a doctor booked on 10-minute boundaries is booked' do
      expect(off_grid(zone.local(2026, 4, 20, 9, 10))).to have_attributes(starts_at: zone.local(2026, 4, 20, 9, 10))
    end

    it 'moves a booking to such a start' do
      booking = perform

      expect(move(booking, zone.local(2026, 4, 20, 10, 20)).starts_at).to eq(zone.local(2026, 4, 20, 10, 20))
    end

    it 'still refuses a time that is taken' do
      perform

      expect { off_grid(zone.local(2026, 4, 20, 9, 10)) }.to raise_error(Scheduling::Error) { |error|
        expect(error.code).to eq('SLOT_CONFLICT')
      }
    end
  end

  context 'with an existing booking' do
    let(:booking) { perform }

    it 'refuses to move it to a start off the grid' do
      expect { move(booking, zone.local(2026, 4, 20, 10, 20)) }.to raise_error(Scheduling::Error) { |error|
        expect(error.code).to eq('START_OFF_GRID')
      }
      expect(booking.reload.starts_at).to eq(starts_at)
    end

    it 'moves it to a start on the grid' do
      expect(move(booking, zone.local(2026, 4, 20, 10)).starts_at).to eq(zone.local(2026, 4, 20, 10))
    end
  end

  context 'with a booking made on a finer grid that is no longer set' do
    let(:grid_override) { 10 }

    it 'does not ask the start again when only the length changes' do
      early = off_grid(zone.local(2026, 4, 20, 9, 10))
      resource.update!(custom_attributes: resource.custom_attributes.except('slot_grid_min'))

      longer = described_class.new(account: account, actor: actor, appointment: early, params: { duration_min: 45 }).perform

      expect(longer).to have_attributes(starts_at: zone.local(2026, 4, 20, 9, 10), duration_min: 45)
    end
  end

  # The length of a visit is the one slot search offers (Scheduling::VisitDuration): a MedElement service has no length of its own (its
  # duration_min is the column default), it is the median of the visits of the doctor. The check of the whole visit against the
  # touching cells of the day uses that length, not service.duration_min, so a booking is accepted exactly where the search offers it.
  context 'with a MedElement service whose visits at the doctor last 60 minutes, two cells' do
    let(:booking_params) { params.except(:ends_at) }

    before do
      create(:scheduling_resource_service_stat, account: account, resource: resource, service: service, median_duration_min: 60)
      windows = ((9 * 60)...(12 * 60)).step(reception_time).map { |minute| { start_minute: minute, end_minute: minute + reception_time } }
      Integrations::Medelement::ScheduleDay.create!(
        account: account, hook: account.hooks.find_by!(app_id: 'medelement'), resource: resource, specialist_code: 'doctor-1',
        date: Date.new(2026, 4, 20), status: 'confirmed', source_checked_at: Time.current, windows: windows
      )
    end

    def book(starts)
      described_class.new(account: account, actor: actor, params: booking_params.merge(starts_at: starts.iso8601)).perform
    end

    def offered_starts
      Scheduling::CompleteSlotSearchService.new(
        account: account, resource_ids: [resource.id], service_id: service.id, from: zone.local(2026, 4, 20, 9), to: zone.local(2026, 4, 20, 12)
      ).perform[:slots].map { |slot| Time.iso8601(slot[:starts_at]).in_time_zone(zone).strftime('%H:%M') }
    end

    it 'offers the starts whose whole visit fits the cells: the last one is 11:00, not 11:30' do
      expect(offered_starts).to eq(%w[09:00 09:30 10:00 10:30 11:00])
    end

    it 'books the last offered start with the 60 minutes of the history, over two cells' do
      booking = book(zone.local(2026, 4, 20, 11))

      expect(booking).to have_attributes(starts_at: zone.local(2026, 4, 20, 11), ends_at: zone.local(2026, 4, 20, 12), duration_min: 60)
    end

    it 'refuses the next grid start, where 30 minutes (the default of the service) would still fit but the visit does not' do
      expect(service.duration_min).to eq(30)

      expect { book(zone.local(2026, 4, 20, 11, 30)) }.to raise_error(Scheduling::Error) { |error|
        expect(error.code).to eq('OUTSIDE_WORKING_HOURS')
      }
      expect(account.scheduling_appointments.reload).to be_empty
    end

    it 'checks the grid of the start with the same length: a start off the grid is refused as off the grid' do
      expect { book(zone.local(2026, 4, 20, 10, 15)) }.to raise_error(Scheduling::Error) { |error|
        expect(error.code).to eq('START_OFF_GRID')
      }
    end
  end
end
