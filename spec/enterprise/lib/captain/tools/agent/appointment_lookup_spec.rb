require 'rails_helper'

RSpec.describe Captain::Tools::Agent::AppointmentLookup do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:patient) { create(:contact, account: account, name: 'Test Son') }
  let(:resource) { create(:scheduling_resource, account: account) }
  let(:starts_at) { 2.days.from_now.change(hour: 10, min: 0, sec: 0) }
  let!(:appointment) do
    create(:scheduling_appointment, account: account, contact: patient, patient_contact: patient, resource: resource,
                                     starts_at: starts_at, ends_at: starts_at + 30.minutes,
                                     client_name: 'Test Son', client_identifier: '940720300129', client_comment: 'Private clinical note')
  end

  def lookup(**params)
    described_class.new(assistant: assistant, conversation: conversation, params: params).perform
  end

  it 'finds another patient by exact IIN without exposing contact, phone, IIN or clinical notes' do
    create(:scheduling_appointment, client_identifier: '940720300129', starts_at: starts_at, ends_at: starts_at + 30.minutes)
    result = lookup(client_identifier: '940720-300 129')
    item = result[:appointments].sole
    expect(item).to include(appointment_id: appointment.id, patient_name: 'Test Son')
    expect(item.keys).to match_array(%i[appointment_id patient_name doctor_name local_date local_time status appointment_access_token])
    expect(item.to_json).not_to include('940720300129', 'Private clinical note')
    expect(Captain::Tools::Agent::AppointmentAccess.resolve(
      token: item[:appointment_access_token], assistant: assistant, conversation: conversation, appointment_id: appointment.id
    )).to eq(appointment)
  end

  it 'requires an exact full name, doctor and bounded day when no IIN is given' do
    expect { lookup(client_name: 'Test') }.to raise_error(ArgumentError)
    expect { lookup(client_name: 'Test Son', resource_id: resource.id, from: starts_at.iso8601, to: (starts_at + 2.days).iso8601) }
      .to raise_error(ArgumentError)
    result = lookup(client_name: '  TEST   SON ', resource_id: resource.id, from: starts_at.beginning_of_day.iso8601)
    expect(result[:appointments].pluck(:appointment_id)).to eq([appointment.id])
    expect(lookup(client_name: 'Test S', resource_id: resource.id, from: starts_at.iso8601)[:appointments]).to eq([])
  end

  it 'does not disclose past appointments for an IIN-only task and requests clarification for many matches' do
    create(:scheduling_appointment, account: account, contact: patient, client_identifier: '940720300129',
                                     starts_at: 2.days.ago, ends_at: 2.days.ago + 30.minutes)
    5.times do |index|
      create(:scheduling_appointment, account: account, contact: patient, client_identifier: '940720300129',
                                       starts_at: starts_at + (index + 1).days, ends_at: starts_at + (index + 1).days + 30.minutes)
    end
    result = lookup(client_identifier: '940720300129')
    expect(result[:appointments].size).to eq(5)
    expect(result).to include(has_more: true, clarification_required: true)
  end
end
