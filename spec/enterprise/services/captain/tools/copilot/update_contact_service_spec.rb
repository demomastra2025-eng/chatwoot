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

    it 'exposes custom_attributes as an object parameter' do
      expect(described_class.parameters[:custom_attributes].type).to eq(:object)
    end
  end
end
