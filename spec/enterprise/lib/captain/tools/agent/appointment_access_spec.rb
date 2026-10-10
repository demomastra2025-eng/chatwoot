require 'rails_helper'

RSpec.describe Captain::Tools::Agent::AppointmentAccess do
  include ActiveSupport::Testing::TimeHelpers

  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:patient) { create(:contact, account: account) }
  let(:appointment) { create(:scheduling_appointment, account: account, contact: patient, patient_contact: patient) }
  let(:token) { described_class.issue(assistant: assistant, conversation: conversation, appointment: appointment) }

  def resolve(value = token, **overrides)
    described_class.resolve(**{ token: value, assistant: assistant, conversation: conversation, appointment_id: appointment.id }.merge(overrides))
  end

  it 'admits exactly the identified appointment, without granting access to another record or conversation' do
    expect(resolve).to eq(appointment)
    other = create(:scheduling_appointment, account: account)
    expect(resolve(appointment_id: other.id)).to be_nil
    expect(resolve(conversation: create(:conversation, account: account))).to be_nil
    expect(resolve(assistant: create(:captain_assistant, account: account))).to be_nil
    expect(resolve(assistant: create(:captain_assistant))).to be_nil
    expect(resolve("#{token}corrupted")).to be_nil
  end

  it 'requires a fresh lookup after the appointment changes and after expiry' do
    issued = token
    appointment.update!(starts_at: appointment.starts_at + 1.hour, ends_at: appointment.ends_at + 1.hour)
    expect(resolve(issued)).to be_nil
    refreshed = described_class.issue(assistant: assistant, conversation: conversation, appointment: appointment)
    travel 21.minutes do
      expect(resolve(refreshed)).to be_nil
    end
  end

  it 'binds patient selection to the assistant and original communication contact with a different purpose' do
    selection = described_class.issue_patient_selection(assistant: assistant, contact: conversation.contact, patient_id: patient.id)
    arguments = { token: selection, assistant: assistant, contact: conversation.contact, patient_id: patient.id }
    expect(described_class.valid_patient_selection?(**arguments)).to be(true)
    expect(described_class.valid_patient_selection?(**arguments.merge(patient_id: conversation.contact_id))).to be(false)
    expect(described_class.valid_patient_selection?(**arguments.merge(contact: patient))).to be(false)
    expect(described_class.valid_patient_selection?(**arguments.merge(token: token))).to be(false)
    expect(resolve(selection)).to be_nil
  end
end
