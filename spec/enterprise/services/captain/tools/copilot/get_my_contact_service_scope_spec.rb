require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::GetMyContactService do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:contact) { create(:contact, account: account, name: 'Aruzhan', last_name: 'A', custom_attributes: { 'source' => 'chat' }) }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let(:tool_context) { Struct.new(:state, :context).new({ conversation: { id: conversation.id } }, {}) }

  def call_tool(tool_id, context: tool_context, **arguments)
    adapter = Captain::Tools::Agent::AccountToolAdapter.new(assistant, tool_id: tool_id)
    JSON.parse(adapter.execute(context, **arguments))
  end

  it 'reads only the contact in the current conversation' do
    other = create(:contact, account: account, name: 'Other')
    payload = call_tool('get_my_contact')

    expect(payload).to include('success' => true)
    expect(payload.fetch('contact')).to include('id' => contact.id, 'first_name' => 'Aruzhan', 'last_name' => 'A')
    expect(payload.to_json).not_to include(other.name)
    expect(described_class.parameters).to be_empty
  end

  it 'updates only the current contact and preserves unrelated and server-owned fields' do
    other = create(:contact, account: account, name: 'Other')
    contact.update!(custom_attributes: contact.custom_attributes.merge('medelement_patient_code' => 'provider-owned'))

    payload = call_tool('update_my_contact',
                        first_name: 'Aigul', last_name: 'B', middle_name: 'C',
                        iin: '940720300129', birth_date: '1994-07-20', gender: 'female',
                        phone_number: '+77001234567', email: 'aigul@example.test')

    expect(payload).to include('success' => true)
    expect(payload.fetch('contact')).to include(
      'first_name' => 'Aigul', 'last_name' => 'B', 'middle_name' => 'C', 'iin' => '940720300129',
      'birth_date' => '1994-07-20', 'gender' => 'female', 'phone_number' => '+77001234567',
      'email' => 'aigul@example.test'
    )
    expect(contact.reload.custom_attributes).to include('source' => 'chat', 'medelement_patient_code' => 'provider-owned')
    expect(other.reload.name).to eq('Other')
  end

  it 'uses contact validations and returns neutral failures without changing the record' do
    expect(call_tool('update_my_contact', email: 'invalid')).to eq('success' => false, 'reason' => 'validation_error')
    expect(call_tool('update_my_contact', iin: '123456789012')).to eq('success' => false, 'reason' => 'validation_error')
    expect(call_tool('update_my_contact', birth_date: '2026-02-30')).to eq('success' => false, 'reason' => 'validation_error')
    expect(call_tool('update_my_contact', contact_id: 2_147_483_647, first_name: 'Wrong'))
      .to eq('success' => false, 'reason' => 'validation_error')
    expect(contact.reload.name).to eq('Aruzhan')

    context = Struct.new(:state, :context).new({ conversation: { id: 2_147_483_647 } }, {})
    expect(call_tool('get_my_contact', context: context)).to eq('success' => false, 'reason' => 'not_found')
    expect(call_tool('update_my_contact', context: context, first_name: 'Wrong')).to eq('success' => false, 'reason' => 'not_found')
  end
end
