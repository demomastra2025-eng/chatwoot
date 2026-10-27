# frozen_string_literal: true

require 'rails_helper'

# The patient card and the upcoming appointments of the patient circle that a reply suggestion reads at its start instead of with
# tools. The circle is the patient and the patients who share the phone; nobody outside it is read. All data is synthetic.
RSpec.describe Captain::ReplySuggestion::PatientPreload do
  include ActiveSupport::Testing::TimeHelpers

  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:contact) do
    create(:contact, account: account, name: 'Айгуль', last_name: 'Ахметова', phone_number: '+77010000001',
                     custom_attributes: { 'birth_date' => '1990-04-02', 'gender' => 'female' })
  end
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let(:doctor) { create(:scheduling_resource, account: account, name: 'Доктор А', timezone: 'Asia/Almaty') }
  let(:tool_ids) { %w[get_my_contact list_my_appointments] }

  around { |example| travel_to(Time.zone.parse('2026-10-09 12:00:00 UTC')) { example.run } }

  before { account.enable_features!('scheduling') }

  def build(ids = tool_ids)
    described_class.build(assistant: assistant, conversation: conversation, tool_ids: ids)
  end

  def appointment(booker, patient: nil, starts_at: 1.day.from_now, **attributes)
    create(:scheduling_appointment, account: account, contact: booker, patient_contact: patient, resource: doctor, starts_at: starts_at,
                                    ends_at: starts_at + 30.minutes, **attributes)
  end

  describe 'the patient card' do
    it 'is what get_my_contact returns, without the empty fields' do
      expect(build[:card]).to eq(Captain::Tools::Account::GetMyContactService.payload(contact).compact_blank)
      expect(build[:card]).to include(first_name: 'Айгуль', last_name: 'Ахметова', birth_date: '1990-04-02', phone_number: '+77010000001')
      expect(build[:card]).not_to have_key(:middle_name)
    end

    it 'is read only for an agent that has get_my_contact' do
      expect(build(%w[list_my_appointments])).not_to have_key(:card)
    end
  end

  describe 'the upcoming appointments' do
    let!(:own) { appointment(contact, starts_at: 2.days.from_now) }

    it 'are read only for an agent that has list_my_appointments' do
      expect(build(%w[get_my_contact])).not_to have_key(:appointments)
    end

    it 'are cards with the ids that cancel and reschedule need, soonest first, and say that they are the agent\'s own' do
      sooner = appointment(contact, starts_at: 1.day.from_now)

      data = build

      expect(data[:appointments].pluck(:id)).to eq([sooner.id, own.id])
      expect(data[:appointments].first).to include(date: '10.10.2026', time: '17:00', doctor: 'Доктор А', status: 'scheduled', own: true)
      expect(data[:appointments_total]).to eq(2)
    end

    it 'are the cards of list_my_appointments, not another format' do
      expected = Captain::AppointmentContext.new(account: account, conversation: conversation).card(own)

      expect(build[:appointments].first).to include(expected)
    end

    it 'leave out the past, the cancelled and the ones of another account' do
      appointment(contact, starts_at: 2.days.ago, status: 'completed')
      appointment(contact, starts_at: 3.days.from_now, status: 'cancelled')
      foreign = create(:account)
      create(:scheduling_appointment, account: foreign, contact: create(:contact, account: foreign), starts_at: 3.days.from_now)

      expect(build[:appointments].pluck(:id)).to eq([own.id])
    end

    it 'are an empty list, not a missing part, when there are none' do
      own.destroy!

      expect(build).to include(appointments: [], appointments_total: 0)
    end

    it 'list six at most and count the rest' do
      7.times { |index| appointment(contact, starts_at: (index + 3).days.from_now) }

      data = build

      expect(data[:appointments].size).to eq(6)
      expect(data[:appointments_total]).to eq(8)
    end

    context 'with a patient who shares the phone' do
      let(:child) { create(:contact, account: account, name: 'Ерлан', last_name: 'Ахметов') }

      before { appointment(contact, patient: child, starts_at: 1.day.from_now) }

      it 'lists the appointment of the child by name, not as one the agent\'s tools act on by id' do
        entry = build[:appointments].find { |item| item[:for] }

        expect(entry).to include(for: 'Ерлан Ахметов', own: false)
        expect(build[:appointments].find { |item| item[:own] }[:id]).to eq(own.id)
      end
    end

    it 'never reads an appointment of a patient outside the circle, or one that someone outside the circle booked for a member' do
      outsider = create(:contact, account: account, name: 'Посторонний')
      appointment(outsider, starts_at: 4.days.from_now)
      appointment(outsider, patient: contact, starts_at: 5.days.from_now)

      expect(build[:appointments].pluck(:id)).to eq([own.id])
    end
  end

  it 'reads nothing when the conversation has no patient' do
    no_patient = instance_double(Conversation, contact_id: nil)

    expect(described_class.build(assistant: assistant, conversation: no_patient, tool_ids: tool_ids)).to eq({})
  end
end
