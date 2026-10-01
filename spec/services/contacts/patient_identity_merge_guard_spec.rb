require 'rails_helper'

RSpec.describe Contacts::PatientIdentityMergeGuard do
  let(:account) { create(:account) }
  let(:owner) { create(:contact, account: account, phone_number: '+77000000001', custom_attributes: { 'medelement_patient_code' => 'primary-1' }) }
  let(:card) do
    create(:contact, account: account, phone_number: nil,
                     custom_attributes: { 'medelement_patient_code' => 'relative-2', 'medelement_patient_card' => true,
                                          'secondary_phones' => [owner.phone_number] })
  end

  it 'rejects merging separate patients in either direction' do
    expect(described_class.allowed?(source_contact: card, target_contact: owner)).to be(false)
    expect(described_class.allowed?(source_contact: owner, target_contact: card)).to be(false)
  end

  it 'does not merge a protected patient card into a phone owner with no provider identity' do
    owner.update!(custom_attributes: {})
    expect(described_class.allowed?(source_contact: card, target_contact: owner)).to be(false)
  end

  it 'keeps technical duplicate merges between chat contacts that are not patient cards' do
    technical = create(:contact, account: account, identifier: 'telegram_personal:technical')
    chat = create(:contact, account: account, phone_number: '+77000000005')
    expect(described_class.allowed?(source_contact: technical, target_contact: chat)).to be(true)
  end

  describe 'M7: a channel merge never involves a patient card' do
    let(:chat_owner) { create(:contact, account: account, name: 'Mother', phone_number: nil, identifier: 'whatsapp_web:55555@lid') }

    it 'refuses a card on either side, with or without an appointment row (Q9)', :aggregate_failures do
      family_card = create(:contact, account: account, name: 'Child', phone_number: '+77000000009',
                                     custom_attributes: { 'medelement_patient_card' => true, 'medelement_patient_code' => 'child-2' })
      expect(described_class.allowed?(source_contact: chat_owner, target_contact: family_card)).to be(false)
      expect(described_class.allowed?(source_contact: family_card, target_contact: chat_owner)).to be(false)

      create(:scheduling_appointment, account: account, contact: chat_owner, patient_contact: family_card).destroy!
      expect(described_class.allowed?(source_contact: chat_owner, target_contact: family_card)).to be(false)
    end

    it 'treats an imported MedElement patient without the card flag as a card (its own number was free)', :aggregate_failures do
      imported = create(:contact, account: account, phone_number: '+77000000009', custom_attributes: { 'medelement_patient_code' => 'son-1' })
      with_iin = create(:contact, account: account, phone_number: '+77000000008', custom_attributes: { 'iin' => '940720300129' })

      expect(described_class.allowed?(source_contact: chat_owner, target_contact: imported)).to be(false)
      expect(described_class.allowed?(source_contact: chat_owner, target_contact: with_iin)).to be(false)
      expect(described_class.allowed?(source_contact: chat_owner, target_contact: owner)).to be(false)
    end

    it 'refuses even when both sides carry the same confirmed code or IIN (card either side)', :aggregate_failures do
      duplicate = build_stubbed(:contact, account: account, custom_attributes: { 'medelement_patient_code' => 'relative-2' })
      same_iin = build_stubbed(:contact, account: account, custom_attributes: { 'iin' => '940720300129' })
      card.update!(identifier: '940720300129')

      expect(described_class.allowed?(source_contact: duplicate, target_contact: card)).to be(false)
      expect(described_class.allowed?(source_contact: same_iin, target_contact: card)).to be(false)
    end

    it 'treats the patient of an appointment as a card, but not its chat contact' do
      patient = create(:contact, account: account)
      create(:scheduling_appointment, account: account, contact: chat_owner, patient_contact: patient)
      technical = create(:contact, account: account, identifier: 'telegram_personal:other')

      expect(described_class.allowed?(source_contact: technical, target_contact: patient)).to be(false)
      expect(described_class.allowed?(source_contact: technical, target_contact: chat_owner)).to be(true)
    end
  end

  describe '.explicit_merge_allowed?' do
    let(:chat) { create(:contact, account: account, phone_number: '+77000000005') }

    it 'refuses to merge a patient card with a contact that lacks its identity in either direction' do
      expect(described_class.explicit_merge_allowed?(base_contact: chat, mergee_contact: card)).to be(false)
      expect(described_class.explicit_merge_allowed?(base_contact: card, mergee_contact: chat)).to be(false)
    end

    it 'treats a contact bound to appointments as a patient card even without the card flag' do
      bound = create(:contact, account: account, phone_number: nil)
      create(:scheduling_appointment, account: account, contact: chat, patient_contact: bound)
      expect(described_class.explicit_merge_allowed?(base_contact: chat, mergee_contact: bound)).to be(false)
    end

    it 'refuses conflicting provider identities and keeps ordinary contact merges available' do
      expect(described_class.explicit_merge_allowed?(base_contact: owner, mergee_contact: card)).to be(false)
      expect(described_class.explicit_merge_allowed?(base_contact: owner, mergee_contact: chat)).to be(true)
      expect(described_class.explicit_merge_allowed?(base_contact: chat, mergee_contact: owner)).to be(true)
    end

    it 'allows a patient card to merge with a duplicate that carries the same IIN' do
      card.update!(identifier: '940720300129')
      duplicate = create(:contact, account: account, custom_attributes: { 'iin' => '940720300129' })
      expect(described_class.explicit_merge_allowed?(base_contact: duplicate, mergee_contact: card)).to be(true)
    end
  end

  describe '.patient_binding_write_in_flight?' do
    let(:appointment) { create(:scheduling_appointment, account: account, contact: owner, patient_contact: card) }
    let(:duplicate) { build_stubbed(:contact, account: account, custom_attributes: { 'medelement_patient_code' => 'relative-2' }) }

    def create_command(status:, write_phase: nil)
      Integrations::Medelement::ProviderCommand.new(
        account: account, appointment: appointment, contact: owner, operation: 'update_patient', status: status,
        idempotency_key: SecureRandom.uuid, execution_state: { 'write_phase' => write_phase }.compact
      ).tap { |command| command.save!(validate: false) }
    end

    it 'blocks a channel merge of the card while its provider write is started' do
      create_command(status: 'queued', write_phase: 'patient_update')

      expect(described_class.patient_binding_write_in_flight?(owner, card)).to be(true)
      expect(described_class.allowed?(source_contact: duplicate, target_contact: card)).to be(false)
    end

    it 'reports a command that awaits reconciliation before its write phase is recorded' do
      create_command(status: 'v2_reconciliation_required')

      expect(described_class.patient_binding_write_in_flight?(card)).to be(true)
    end

    it 'ignores finished, cancelled and not yet started commands' do
      create_command(status: 'succeeded', write_phase: 'patient_update')
      create_command(status: 'cancelled', write_phase: 'patient_update')
      create_command(status: 'queued')

      expect(described_class.patient_binding_write_in_flight?(card)).to be(false)
      expect(described_class.patient_binding_write_in_flight?(Contact.new)).to be(false)
    end

    it 'ignores terminal failed and declined commands even after their write phase started' do
      create_command(status: 'failed', write_phase: 'patient_update')
      create_command(status: 'declined', write_phase: 'reception_create')

      expect(described_class.patient_binding_write_in_flight?(card)).to be(false)
    end
  end

  describe '.lock_patient_bindings!' do
    it 'locks the appointments bound to or chatting for either contact in id order before a merge re-checks them' do
      bound = Array.new(2) { create(:scheduling_appointment, account: account, contact: owner, patient_contact: card) }
      own = create(:scheduling_appointment, account: account, contact: owner)
      create(:scheduling_appointment, account: account, contact: create(:contact, account: account))
      statements = []
      collect = ->(*, payload) { statements << payload[:sql] }

      ids = ActiveSupport::Notifications.subscribed(collect, 'sql.active_record') do
        described_class.lock_patient_bindings!(owner, card, nil)
      end

      expect(ids).to eq((bound.map(&:id) + [own.id]).sort)
      expect(statements.grep(/FROM "scheduling_appointments".*"patient_contact_id" IN .* OR .*"contact_id" IN .*ORDER BY .*FOR UPDATE/)).to be_one
      expect(described_class.lock_patient_bindings!(nil)).to eq([])
    end
  end

  it 'does not let a matching provider code hide a conflicting confirmed IIN' do
    owner.assign_attributes(identifier: '940720300119', custom_attributes: { 'medelement_patient_code' => 'relative-2' })
    card.update!(identifier: '940720300129')
    expect(described_class.allowed?(source_contact: card, target_contact: owner)).to be(false)
  end
end
