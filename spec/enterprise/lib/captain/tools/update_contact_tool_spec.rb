require 'rails_helper'

RSpec.describe Captain::Tools::UpdateContactTool, type: :model do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:tool) { described_class.new(assistant) }

  it 'returns normalized update_contact payload' do
    contact = create(:contact, account: account, name: 'Old Name')
    conversation = create(:conversation, account: account, contact: contact)
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id }, contact: { id: contact.id } })

    payload = JSON.parse(tool.perform(tool_context, name: 'New Name', custom_attributes: { vip: true }))

    expect(payload).to include('action' => 'update_contact')
    expect(payload['contact']).to include(
      'id' => contact.id,
      'name' => 'New Name',
      'contact_type' => contact.contact_type,
      'additional_attributes' => contact.additional_attributes,
      'custom_attributes' => { 'vip' => true }
    )
  end

  it 'rejects a non-existent birth date, names the field and leaves the contact unchanged' do
    contact = create(:contact, account: account, name: 'Old Name', custom_attributes: { 'birth_date' => '1994-07-20' })
    conversation = create(:conversation, account: account, contact: contact)
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id }, contact: { id: contact.id } })

    result = tool.perform(tool_context, name: 'New Name', custom_attributes: { birth_date: '1990-13-40' })

    expect(result).to include('custom_attributes.birth_date')
    expect(contact.reload).to have_attributes(name: 'Old Name', custom_attributes: { 'birth_date' => '1994-07-20' })
  end

  it 'exposes custom_attributes as an object parameter' do
    expect(described_class.parameters[:custom_attributes].type).to eq('object')
  end
end
