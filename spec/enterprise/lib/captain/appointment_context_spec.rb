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

  it 'excludes another contact, account, and representative booking' do
    other_contact = create(:contact, account: account)
    create(:scheduling_appointment, account: account, contact: other_contact, conversation: conversation,
                                    resource: resource, starts_at: 1.hour.from_now)
    create(:scheduling_appointment, account: account, contact: other_contact, patient_contact: contact,
                                    resource: resource, starts_at: 2.hours.from_now)
    foreign_account = create(:account)
    create(:scheduling_appointment, account: foreign_account, contact: create(:contact, account: foreign_account),
                                    starts_at: 3.hours.from_now)

    expect(context.appointments.count).to eq(0)
    expect(context.nearest).to be_nil
    expect(JSON.parse(context.block('nearest'))).to be_nil
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
end
