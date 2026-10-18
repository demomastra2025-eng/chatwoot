require 'rails_helper'

RSpec.describe Contacts::DuplicateCandidatesService do
  subject(:service) { described_class.new(account: account) }

  let(:account) { create(:account) }

  describe '#perform' do
    it 'finds duplicate contacts that share a valid IIN even when MedElement patient codes differ' do
      first = create(
        :contact,
        account: account,
        name: 'Айгуль',
        last_name: 'Ахметова',
        phone_number: '+77011112233',
        identifier: '940720300129',
        custom_attributes: { 'iin' => '940720300129', 'medelement_patient_code' => 'card-1' }
      )
      second = create(
        :contact,
        account: account,
        name: 'Айгуль',
        last_name: 'Ахметова',
        phone_number: nil,
        custom_attributes: {
          'iin' => '940720300129',
          'medelement_patient_code' => 'card-2',
          'medelement_patient_card' => true,
          'secondary_phones' => ['+77011112233']
        }
      )

      results = service.perform

      expect(results.size).to eq(1)
      expect(results.first[:primary_contact][:id]).to eq(first.id)
      expect(results.first[:conflicting_contact][:id]).to eq(second.id)
      expect(results.first[:match_reasons]).to include('same_iin', 'shared_phone', 'same_full_name')
    end

    it 'finds duplicate contacts with matching first and last name in general CRM accounts' do
      first = create(:contact, account: account, name: 'Иван', last_name: 'Петров', phone_number: '+77015556677')
      second = create(:contact, account: account, name: 'Иван Петров', last_name: '', phone_number: nil, email: 'ivan@example.com')

      results = service.perform

      expect(results.size).to eq(1)
      expect(results.first[:primary_contact][:id]).to eq(first.id)
      expect(results.first[:conflicting_contact][:id]).to eq(second.id)
      expect(results.first[:match_reasons]).to include('same_full_name')
    end

    it 'excludes family members who share a phone number but have different identities' do
      mother = create(
        :contact,
        account: account,
        name: 'Динара',
        last_name: 'Серикова',
        phone_number: '+77019998877',
        custom_attributes: { 'medelement_patient_code' => 'mother-1', 'birth_date' => '1988-03-10' }
      )
      child = create(
        :contact,
        account: account,
        name: 'Алихан',
        last_name: 'Сериков',
        phone_number: nil,
        custom_attributes: {
          'medelement_patient_code' => 'child-2',
          'medelement_patient_card' => true,
          'medelement_shared_phone_owner_id' => mother.id,
          'birth_date' => '2018-06-15'
        }
      )
      expect(child).to be_present

      expect(service.perform).to be_empty
    end

    it 'excludes pairs dismissed by a manager and marks open sync conflicts as ignored' do
      user = create(:user, account: account, role: :agent)
      first = create(:contact, account: account, name: 'Мадина', last_name: 'Алиева', phone_number: '+77014443322')
      second = create(:contact, account: account, name: 'Мадина', last_name: 'Алиева', phone_number: nil)
      run = Integrations::Medelement::SyncRun.create!(account: account, trigger: 'manual', status: 'partial')
      conflict = Integrations::Medelement::ConflictTracker.new(sync_run: run).record!(
        phase: 'contacts',
        entity_type: 'contact',
        conflict_type: 'phone_owned_by_another_contact',
        entity_key: 'card-2',
        details: { contact_id: second.id, conflicting_contact_id: first.id, reason: 'phone_owned_by_another_contact' }
      )

      expect(service.perform.size).to eq(1)

      service.dismiss!(contact_id: first.id, duplicate_contact_id: second.id, user: user)

      expect(service.perform).to be_empty
      expect(conflict.reload.status).to eq('ignored')
    end
  end
end
