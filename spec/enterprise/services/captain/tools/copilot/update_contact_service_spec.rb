require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::UpdateContactService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:contact) { create(:contact, account: account, name: 'Aruzhan', custom_attributes: { 'source' => 'site' }) }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let(:service) { described_class.new(assistant, user: user, conversation: conversation) }

  describe '#execute' do
    it 'updates the current contact and returns a structured payload' do
      payload = JSON.parse(
        service.execute(name: 'Aruzhan K', custom_attributes: { 'source' => 'captain', 'vip' => true })
      )

      contact.reload

      expect(payload).to include('action' => 'update_contact')
      expect(payload.fetch('contact')).to include(
        'id' => contact.id,
        'name' => 'Aruzhan K',
        'custom_attributes' => include('source' => 'captain', 'vip' => true)
      )
      expect(contact.name).to eq('Aruzhan K')
      expect(contact.custom_attributes).to include(
        'source' => 'captain',
        'vip' => true
      )
    end

    it 'rejects a non-existent birth date with a failure that names the field and leaves the contact unchanged' do
      contact.update!(custom_attributes: contact.custom_attributes.merge('birth_date' => '1994-07-20'))
      before_update = contact.reload.attributes

      ['2026-02-30', '2026-04-31', '1990-13-40', 'not-a-date'].each do |value|
        result = service.execute(name: 'Changed', custom_attributes: { 'birth_date' => value, 'vip' => true })

        expect(result).to include('custom_attributes.birth_date')
        expect(contact.reload.attributes).to eq(before_update)
      end
    end

    it 'saves an existing birth date and accepts the JSON-string form of custom attributes' do
      service.execute(custom_attributes: { 'birth_date' => '2024-02-29' })
      expect(contact.reload.custom_attributes['birth_date']).to eq('2024-02-29')

      result = service.execute(custom_attributes: '{"birth_date":"2026-02-30"}')
      expect(result).to include('custom_attributes.birth_date')
      expect(contact.reload.custom_attributes['birth_date']).to eq('2024-02-29')
    end

    it 'exposes custom_attributes as an object parameter' do
      expect(described_class.parameters[:custom_attributes].type).to eq(:object)
    end
  end
end
