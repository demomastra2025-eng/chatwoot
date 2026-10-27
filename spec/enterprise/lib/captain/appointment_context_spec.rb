require 'rails_helper'

RSpec.describe Captain::AppointmentContext do
  let(:account) { create(:account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let(:other_conversation) { create(:conversation, account: account, contact: contact) }
  let(:resource) { create(:scheduling_resource, account: account, name: 'Доктор А', timezone: 'Asia/Almaty') }
  let(:context) { described_class.new(account: account, conversation: conversation) }

  around do |example|
    travel_to(Time.zone.parse('2026-10-09 12:00:00 UTC')) { example.run }
  end

  before { account.enable_features!('scheduling') }

  it 'uses the shared envelope with six upcoming, three past and three planned cancellation slots' do
    ongoing = appointment(starts_at: 10.minutes.ago)
    7.times { |index| appointment(starts_at: (index + 1).days.from_now) }
    4.times { |index| appointment(starts_at: (index + 1).days.ago) }
    5.times { |index| appointment(starts_at: (index + 1).days.from_now, status: 'cancelled') }
    summary = context.compact_summary

    expect(summary).to include(total: 17, shown: 12, display: 'Показано 12 из 17')
    expect(summary[:groups].map { |group| [group[:shown], group[:total]] }).to eq([[6, 8], [3, 4], [3, 5]])
    expect(summary[:groups].first[:items].first[:id]).to eq(ongoing.id)
    expect(JSON.parse(context.block('summary'))['shown']).to eq(12)
  end

  def appointment(starts_at:, status: 'scheduled', **attributes)
    create(:scheduling_appointment, account: account, contact: contact, resource: resource,
                                    starts_at: starts_at, ends_at: starts_at + 30.minutes, status: status, **attributes)
  end

  it 'selects an in-progress visit until its end, then the next visit' do
    active = appointment(starts_at: 10.minutes.ago)
    following = appointment(starts_at: 2.days.from_now, conversation: other_conversation)
    appointment(starts_at: 4.days.from_now, status: 'cancelled')

    expect(context.nearest.id).to eq(active.id)
    expect(context.nearest(now: 21.minutes.from_now).id).to eq(following.id)
  end

  it 'selects the latest finished active visit and most recently starting cancellation' do
    appointment(starts_at: 3.days.ago)
    latest = appointment(starts_at: 1.day.ago, status: 'completed')
    appointment(starts_at: 2.days.from_now, status: 'cancelled')
    cancelled = appointment(starts_at: 3.days.from_now, status: 'cancelled')

    expect(context.last_past.id).to eq(latest.id)
    expect(context.last_cancelled.id).to eq(cancelled.id)
  end

  it 'excludes another contact, account, and representative booking from the own appointments' do
    other_contact = create(:contact, account: account)
    create(:scheduling_appointment, account: account, contact: other_contact, conversation: conversation,
                                    resource: resource, starts_at: 1.hour.from_now)
    create(:scheduling_appointment, account: account, contact: other_contact, patient_contact: contact,
                                    resource: resource, starts_at: 2.hours.from_now)
    appointment(starts_at: 10.minutes.from_now, patient_contact: other_contact)
    appointment(starts_at: 1.hour.ago, status: 'completed', patient_contact: other_contact)
    appointment(starts_at: 1.day.from_now, status: 'cancelled', patient_contact: other_contact)
    foreign_account = create(:account)
    create(:scheduling_appointment, account: foreign_account, contact: create(:contact, account: foreign_account),
                                    starts_at: 3.hours.from_now)

    expect(context.appointments.count).to eq(0)
    expect(context.nearest).to be_nil
    expect(context.last_past).to be_nil
    expect(context.last_cancelled).to be_nil
    %w[nearest last_past last_cancelled].each { |key| expect(JSON.parse(context.block(key))).to be_nil }
    expect(JSON.parse(context.block('all'))).to include('total' => 0, 'appointments' => [])
  end

  it 'keeps legacy and explicitly selected own visits across conversations' do
    legacy = appointment(starts_at: 1.hour.from_now, patient_contact: nil)
    selected = appointment(starts_at: 2.hours.from_now, patient_contact: contact, conversation: other_conversation)

    expect(context.appointments.pluck(:id)).to contain_exactly(legacy.id, selected.id)
    expect(context.list.fetch(:appointments).pluck(:id)).to contain_exactly(legacy.id, selected.id)
  end

  # Suggestion eval 27.10 (c76-1231671, c43-1220644, c77-1221272, c78-1218989): the visit to cancel was a child's, booked from the
  # parent's chat, and the lookup covered only the contact's own card, so the draft said there was nothing to cancel.
  describe 'the patients linked to the contact' do
    let(:child) { create(:contact, account: account, name: 'Айя') }

    it 'lists a visit booked from this chat for another patient and names that patient on its card' do
      own = appointment(starts_at: 1.hour.from_now)
      child_visit = appointment(starts_at: 1.day.from_now, patient_contact: child, client_name: 'Ким Айя Ерлановна')

      expect(context.linked_appointments.pluck(:id)).to contain_exactly(own.id, child_visit.id)
      cards = context.list(status: 'scheduled').fetch(:appointments)
      expect(cards.find { |card| card[:id] == child_visit.id }).to include(patient_name: 'Ким Айя Ерлановна')
      expect(cards.find { |card| card[:id] == own.id }).not_to have_key(:patient_name)
      expect(context.list(status: 'scheduled', doctor: 'Доктор').fetch(:total)).to eq(2)
    end

    it 'keeps the own appointments, the prompt cards and the nearest visit of the contact alone' do
      own = appointment(starts_at: 2.days.from_now)
      appointment(starts_at: 1.day.from_now, patient_contact: child)
      appointment(starts_at: 3.days.ago, status: 'completed', patient_contact: child)

      expect(context.appointments.pluck(:id)).to eq([own.id])
      expect(context.nearest.id).to eq(own.id)
      expect(context.last_past).to be_nil
      expect(JSON.parse(context.block('all'))).to include('total' => 1)
      expect(context.compact_summary[:groups].flat_map { |group| group[:items] }.pluck(:id)).to eq([own.id])
    end

    it 'lists the visits of a patient card recorded as one of the contact, booked from the card own chat' do
      sibling = create(:contact, account: account, name: 'Дина',
                                 custom_attributes: { Scheduling::PatientContextQuery::CONTACT_IDS_KEY => [contact.id] })
      visit = create(:scheduling_appointment, account: account, contact: sibling, patient_contact: sibling, resource: resource,
                                              starts_at: 2.days.from_now, ends_at: 2.days.from_now + 30.minutes, client_name: 'Дина')

      expect(context.appointments.count).to eq(0)
      expect(context.linked_appointments.pluck(:id)).to eq([visit.id])
      expect(context.list.fetch(:appointments).sole).to include(id: visit.id, patient_name: 'Дина')
    end

    it 'does not widen the circle to a contact that only shares the account, or to another account' do
      stranger = create(:contact, account: account)
      create(:scheduling_appointment, account: account, contact: stranger, patient_contact: child, resource: resource,
                                      starts_at: 1.day.from_now, ends_at: 1.day.from_now + 30.minutes)
      create(:scheduling_appointment, account: account, contact: stranger, patient_contact: contact, resource: resource,
                                      starts_at: 2.hours.from_now, ends_at: 150.minutes.from_now)
      foreign_account = create(:account)
      create(:scheduling_appointment, account: foreign_account, contact: create(:contact, account: foreign_account),
                                      starts_at: 3.hours.from_now)

      expect(context.linked_appointments.count).to eq(0)
      expect(context.list).to include(total: 0, appointments: [])
    end
  end

  # The list covers the contact and the patients linked to it only, so an empty list proves nothing: it says so to the agent.
  it 'tells the agent that an empty list is no proof that the patient has no appointment' do
    expect(context.list).to include(total: 0, appointments: [], note: described_class::NOTHING_FOUND_NOTE)
    expect(context.list(status: 'scheduled', date_from: '2026-10-10')).to include(note: described_class::NOTHING_FOUND_NOTE)
    expect(described_class::NOTHING_FOUND_NOTE).to include('Never tell the patient', 'nothing to cancel', 'search_appointments', 'staff')

    appointment(starts_at: 1.day.from_now)
    expect(context.list).not_to have_key(:note)
    expect(context.list(offset: 10_000)).not_to have_key(:note)
  end

  it 'renders empty, single, and capped many-appointment blocks without system data' do
    expect(JSON.parse(context.block('all'))).to include('total' => 0, 'empty' => 'нет записей')
    single = appointment(starts_at: 1.day.from_now, service_name_snapshot: 'Приём',
                         external_ref: 'private-provider-ref', client_phone: '+70000000000')
    expect(JSON.parse(context.block('nearest'))).to eq(
      'id' => single.id, 'status' => 'scheduled', 'date' => '10.10.2026',
      'time' => '17:00', 'doctor' => 'Доктор А', 'service' => 'Приём'
    )
    4.times { |index| appointment(starts_at: (index + 2).days.from_now) }
    3.times { |index| appointment(starts_at: (index + 1).days.ago) }
    2.times { |index| appointment(starts_at: (index + 1).days.from_now, status: 'cancelled') }

    block = JSON.parse(context.block('all'))
    expect(block).to include('total' => 10, 'upcoming' => 5, 'past' => 3, 'cancelled' => 2)
    expect(block.fetch('appointments').length).to eq(6)
    expect(block.fetch('appointments').last.fetch('status')).to eq('cancelled')
    expect(block.fetch('hint')).to include('list_my_appointments')
    expect(block.to_json).not_to include('private-provider-ref', '+70000000000', 'payment', 'medelement')
  end

  it 'shows a reschedule MedElement has not confirmed next to the confirmed time, never as the visit time' do
    unconfirmed = appointment(
      starts_at: Time.zone.parse('2026-10-15 05:00:00 UTC'),
      custom_attributes: {
        'medelement_move_request' => {
          'state' => 'needs_reconciliation', 'confirmed_starts_at' => '2026-10-15T05:00:00.000000Z',
          'requested_starts_at' => '2026-10-14T05:30:00.000000Z'
        }
      }
    )
    plain = appointment(starts_at: Time.zone.parse('2026-10-16 05:00:00 UTC'))

    expect(JSON.parse(context.block('nearest'))).to include(
      'id' => unconfirmed.id, 'date' => '15.10.2026', 'time' => '10:00',
      'reschedule' => { 'state' => 'needs_reconciliation', 'requested_time_confirmed' => false,
                        'requested_date' => '14.10.2026', 'requested_time' => '10:30' }
    )
    expect(context.card(plain)).not_to have_key(:reschedule)
  end

  it 'filters by status, date, and doctor and pages with a hard cap' do
    first = appointment(starts_at: 1.day.from_now)
    second = appointment(starts_at: 2.days.from_now, status: 'confirmed')
    appointment(starts_at: 3.days.from_now, status: 'cancelled')
    21.times { |index| appointment(starts_at: (index + 4).days.from_now) }

    first_page = context.list(status: 'scheduled', limit: 400)
    expect(first_page).to include(success: true, total: 23, has_more: true)
    expect(first_page.fetch(:appointments).length).to eq(20)
    page = context.list(status: 'scheduled', doctor: 'доктор а', limit: 20, offset: 20)
    expect(page).to include(success: true, total: 23, has_more: false)
    expect(page.fetch(:appointments).length).to eq(3)
    expect(page.fetch(:appointments).pluck(:id)).to include(first.id, second.id)
    expect(context.list(offset: 10_000)).to include(total: 24, has_more: false, appointments: [])
    expect(context.list(status: 'cancelled').fetch(:total)).to eq(1)
    expect(context.list(date_from: '2026-10-10', date_to: '2026-10-10').fetch(:total)).to eq(1)
    expect(context.list(limit: 21).fetch(:appointments).length).to eq(20)
    expect { context.list(limit: -1) }.to raise_error(ArgumentError)
    expect { context.list(date_from: 'invalid') }.to raise_error(ArgumentError)
  end

  it 'keeps completed and no-show statuses separate and accepts a doctor substring' do
    completed = appointment(starts_at: 2.days.ago, status: 'completed')
    missed = appointment(starts_at: 1.day.ago, status: 'no_show')

    expect(context.list(status: 'completed').fetch(:appointments).pluck(:id)).to eq([completed.id])
    expect(context.list(status: 'no_show').fetch(:appointments).pluck(:id)).to eq([missed.id])
    expect(context.list(doctor: 'Доктор').fetch(:total)).to eq(2)
    expect(context.list(doctor: 'Другой').fetch(:appointments)).to be_empty
  end

  it 'filters calendar dates using the clinic timezone when the account timezone is unset' do
    appointment(starts_at: Time.zone.parse('2026-10-09 18:59:00 UTC'))
    at_start = appointment(starts_at: Time.zone.parse('2026-10-09 19:00:00 UTC'))
    at_end = appointment(starts_at: Time.zone.parse('2026-10-10 18:59:00 UTC'))
    appointment(starts_at: Time.zone.parse('2026-10-10 19:00:00 UTC'))

    page = context.list(date_from: '2026-10-10', date_to: '2026-10-10')
    expect(page.fetch(:appointments).pluck(:id)).to contain_exactly(at_start.id, at_end.id)
    expect(page.fetch(:appointments).pluck(:date)).to eq(['10.10.2026', '10.10.2026'])
  end

  it 'uses a configured reporting timezone for the date range' do
    account.update!(reporting_timezone: 'Europe/Moscow')
    appointment(starts_at: Time.zone.parse('2026-10-09 19:00:00 UTC'))

    expect(context.list(date_from: '2026-10-10', date_to: '2026-10-10').fetch(:total)).to eq(0)
  end

  it 'accepts only valid ISO calendar dates' do
    expect { context.list(date_from: '2026-10-10T12:00:00Z') }.to raise_error(ArgumentError, 'Invalid date')
    expect { context.list(date_to: '2026-02-30') }.to raise_error(ArgumentError, 'Invalid date')
  end
end
