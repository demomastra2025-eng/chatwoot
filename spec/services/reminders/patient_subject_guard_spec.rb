require 'rails_helper'

RSpec.describe Reminders::PatientSubjectGuard do
  let(:account) { create(:account) }
  let(:owner) { create(:contact, account: account, phone_number: '+77000000001') }
  let(:patient) { create(:contact, account: account, name: 'Relative', phone_number: nil) }
  let(:appointment) { create(:scheduling_appointment, account: account, contact: owner, patient_contact: patient) }

  describe '.notification_contact' do
    it 'uses the shared communication owner while the separate patient has no own primary number' do
      expect(described_class.notification_contact(appointment)).to eq(owner)
    end

    it 'gives priority to the separate patient own primary number as soon as the card has one' do
      patient.update!(phone_number: '+77000000002')

      expect(described_class.notification_contact(appointment.reload)).to eq(patient)
    end

    it 'returns to the shared owner only after the own primary number is removed' do
      patient.update!(phone_number: '+77000000002')
      patient.update!(phone_number: nil)

      expect(described_class.notification_contact(appointment.reload)).to eq(owner)
    end

    it 'keeps the communication contact for an appointment of the owner itself' do
      own_visit = create(:scheduling_appointment, account: account, contact: owner, patient_contact: owner)
      unbound_visit = create(:scheduling_appointment, account: account, contact: owner)

      expect(described_class.notification_contact(own_visit)).to eq(owner)
      expect(described_class.notification_contact(unbound_visit)).to eq(owner)
    end

    it 'never routes to a patient card of another account' do
      foreign_patient = create(:contact, phone_number: '+77000000003')
      appointment.update_column(:patient_contact_id, foreign_patient.id) # rubocop:disable Rails/SkipsModelValidations

      expect(described_class.notification_contact(appointment.reload)).to eq(owner)
    end

    it 'keeps the contact of non-appointment remindables' do
      conversation = create(:conversation, account: account, contact: owner)

      expect(described_class.notification_contact(conversation)).to eq(owner)
    end

    it 'keeps the shared owner when the card number is one of the owner chat identities' do
      family_inbox = create(:inbox, account: account)
      create(:contact_inbox, contact: owner, inbox: family_inbox, source_id: '77000000009')
      create(:contact_inbox, contact: create(:contact, account: account), inbox: family_inbox, source_id: '77000000002')
      patient.update!(phone_number: '+77000000009')

      expect(described_class.notification_contact(appointment.reload)).to eq(owner)

      patient.update!(phone_number: '+77000000002')
      expect(described_class.notification_contact(appointment.reload)).to eq(patient)
    end
  end

  describe '.patient_route? and .foreign_chat_identity?' do
    let(:inbox) { create(:inbox, account: account) }

    it 'recognises a touch routed to the separate patient card only' do
      patient.update!(phone_number: '+77000000002')
      patient_touch = create(:reminder, account: account, remindable: appointment.reload, target_inbox: inbox)
      own_visit_touch = create(:reminder, account: account, remindable: create(:scheduling_appointment, account: account, contact: owner),
                                          target_inbox: inbox)

      expect(patient_touch.target_contact_id).to eq(patient.id)
      expect(described_class.patient_route?(patient_touch)).to be(true)
      expect(described_class.patient_route?(own_visit_touch)).to be(false)
    end

    it 'detects a source already held by another contact in the same inbox only' do
      create(:contact_inbox, contact: owner, inbox: inbox, source_id: '77000000009')

      expect(described_class.foreign_chat_identity?(inbox: inbox, contact: patient, source_id: '77000000009')).to be(true)
      expect(described_class.foreign_chat_identity?(inbox: inbox, contact: owner, source_id: '77000000009')).to be(false)
      expect(described_class.foreign_chat_identity?(inbox: create(:inbox, account: account), contact: patient, source_id: '77000000009'))
        .to be(false)
      expect(described_class.foreign_chat_identity?(inbox: inbox, contact: patient, source_id: nil)).to be(false)
    end
  end

  describe '.foreign_reply?' do
    let(:inbox) { create(:inbox, account: account) }

    def incoming_from(sender)
      contact_inbox = create(:contact_inbox, contact: sender, inbox: inbox)
      conversation = create(:conversation, account: account, inbox: inbox, contact: sender, contact_inbox: contact_inbox)
      create(:message, account: account, inbox: inbox, conversation: conversation, sender: sender, message_type: :incoming)
    end

    it 'treats an ordinary reply of the shared owner as foreign to the separate patient' do
      expect(described_class.foreign_reply?(appointment, incoming_from(owner))).to be(true)
    end

    it 'attributes a reply from the separate patient own contact to that patient' do
      patient.update!(phone_number: '+77000000002')

      expect(described_class.foreign_reply?(appointment.reload, incoming_from(patient))).to be(false)
    end

    it 'does not restrict replies for appointments without a separate patient' do
      own_visit = create(:scheduling_appointment, account: account, contact: owner)

      expect(described_class.foreign_reply?(own_visit, incoming_from(owner))).to be(false)
    end
  end
end
