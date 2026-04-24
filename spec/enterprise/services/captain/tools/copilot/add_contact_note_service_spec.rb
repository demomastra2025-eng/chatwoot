require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::AddContactNoteService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:contact) { create(:contact, account: account, name: 'Aruzhan') }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let(:service) { described_class.new(assistant, user: user, conversation: conversation) }

  it 'returns a normalized payload for the created contact note' do
    payload = JSON.parse(service.execute(note: 'VIP клиент'))

    note = contact.notes.order(:id).last
    expect(payload).to include(
      'action' => 'add_contact_note',
      'contact_id' => contact.id,
      'contact_name' => 'Aruzhan',
      'note_id' => note.id,
      'note' => 'VIP клиент'
    )
  end
end
