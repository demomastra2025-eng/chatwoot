require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::UpdateContactService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:contact) { create(:contact, account: account, name: 'Aruzhan', custom_attributes: { 'source' => 'site' }) }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let(:service) { described_class.new(assistant, user: user, conversation: conversation) }

  describe '#execute' do
    it 'updates the current contact using object custom_attributes' do
      service.execute(name: 'Aruzhan K', custom_attributes: { 'source' => 'captain', 'vip' => true })

      contact.reload

      expect(contact.name).to eq('Aruzhan K')
      expect(contact.custom_attributes).to include(
        'source' => 'captain',
        'vip' => true
      )
    end
  end
end
