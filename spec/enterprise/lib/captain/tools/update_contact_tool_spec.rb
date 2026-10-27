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

  # Suggestion eval 27.10 (c74-1245386): a payment phone number the patient sent was read as the ID number, and the tool took any text.
  # Review of quality-fixes-1 (M5, L3): the identifier is the IIN of a patient in the accounts whose contact attributes hold an IIN only, and the iin of
  # the custom attributes is the same number written the other way.
  context 'with an identifier' do
    let(:contact) { create(:contact, account: account, name: 'Old Name', identifier: nil) }
    let(:conversation) { create(:conversation, account: account, contact: contact) }
    let(:tool_context) { Struct.new(:state).new({ conversation: { id: conversation.id }, contact: { id: contact.id } }) }

    before { create(:custom_attribute_definition, account: account, attribute_key: 'iin', attribute_model: :contact_attribute) }

    it 'refuses a phone number written as the iin of the custom attributes, as a hash or as its JSON text, and leaves the contact unchanged' do
      [{ iin: '87011234567' }, { 'iin' => '+7 701 123 45 67' }, '{"iin": "Kaspi 7011234567"}'].each do |attributes|
        result = tool.perform(tool_context, name: 'New Name', custom_attributes: attributes)

        expect(result).to include('Invalid IIN'), attributes.inspect
        expect(contact.reload).to have_attributes(name: 'Old Name', identifier: nil, custom_attributes: {})
      end
    end

    it 'writes the iin of the custom attributes when it is an IIN, and other custom fields as before' do
      payload = JSON.parse(tool.perform(tool_context, custom_attributes: { iin: '900101300027', vip: true }))

      expect(payload['contact']['custom_attributes']).to include('iin' => '900101300027', 'vip' => true)
    end

    it 'takes the identifier as it is given in an account whose contact attributes hold no IIN' do
      account.custom_attribute_definitions.destroy_all

      payload = JSON.parse(tool.perform(tool_context, identifier: 'customer-77', custom_attributes: { iin: 'not checked' }))

      expect(payload['contact']).to include('identifier' => 'customer-77')
      expect(contact.reload.identifier).to eq('customer-77')
    end

    it 'writes an IIN of 12 digits with the check digit, as the digits only' do
      payload = JSON.parse(tool.perform(tool_context, identifier: '900101 300027'))

      expect(payload['contact']).to include('identifier' => '900101300027')
      expect(contact.reload.identifier).to eq('900101300027')
    end

    it 'refuses a phone number or any other text as the IIN and leaves the contact unchanged' do
      ['+7 701 123 45 67', '87011234567', '77011234567', '900101300028', '90010130002', '9001013000271', 'abc', 'Kaspi 7011234567'].each do |value|
        result = tool.perform(tool_context, name: 'New Name', identifier: value)

        expect(result).to include('Invalid IIN'), value
        expect(contact.reload).to have_attributes(name: 'Old Name', identifier: nil)
      end
    end

    it 'leaves the identifier alone when none is passed or the text is blank' do
      contact.update!(identifier: '900101300027')

      JSON.parse(tool.perform(tool_context, name: 'New Name'))
      JSON.parse(tool.perform(tool_context, name: 'Newer Name', identifier: '  '))

      expect(contact.reload).to have_attributes(name: 'Newer Name', identifier: '900101300027')
    end
  end

  it 'exposes custom_attributes as an object parameter' do
    expect(described_class.parameters[:custom_attributes].type).to eq('object')
  end
end
