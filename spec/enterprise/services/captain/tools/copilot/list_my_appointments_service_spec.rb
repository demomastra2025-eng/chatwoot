require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::ListMyAppointmentsService do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let(:tool_context) { Struct.new(:state, :context).new({ conversation: { id: conversation.id } }, {}) }

  before { account.enable_features!('scheduling') }

  def call_tool(**arguments)
    adapter = Captain::Tools::Agent::AccountToolAdapter.new(assistant, tool_id: 'list_my_appointments')
    JSON.parse(adapter.execute(tool_context, **arguments))
  end

  it 'returns only the current contact appointments across conversations' do
    own = create(:scheduling_appointment, account: account, contact: contact, external_ref: 'private-command')
    another_channel = create(:conversation, account: account, contact: contact)
    other_own = create(:scheduling_appointment, account: account, contact: contact, patient_contact: contact,
                                              conversation: another_channel)
    other_contact = create(:contact, account: account)
    create(:scheduling_appointment, account: account, contact: other_contact, conversation: conversation)
    create(:scheduling_appointment, account: account, contact: other_contact, patient_contact: contact)
    create(:scheduling_appointment, account: account, contact: contact, patient_contact: other_contact, conversation: conversation)
    create(:scheduling_appointment, account: create(:account))

    payload = call_tool
    expect(payload).to include('success' => true, 'total' => 2, 'has_more' => false)
    expect(payload.fetch('appointments').pluck('id')).to contain_exactly(own.id, other_own.id)
    expect(payload.fetch('appointments').first.keys).to match_array(%w[id status date time doctor service])
    expect(payload.to_json).not_to include('private-command', 'payment_status', 'client_phone')
  end

  it 'returns neutral failures for invalid filters and a missing contact' do
    expect(call_tool(status: 'private')).to eq('success' => false, 'reason' => 'validation_error')
    expect(call_tool(limit: -1)).to eq('success' => false, 'reason' => 'validation_error')
    expect(call_tool(date_from: '2026-10-10T12:00:00Z')).to eq('success' => false, 'reason' => 'validation_error')
    expect(call_tool(date_to: '2026-02-30')).to eq('success' => false, 'reason' => 'validation_error')
    absent_context = Struct.new(:state, :context).new({ conversation: { id: 2_147_483_647 } }, {})
    adapter = Captain::Tools::Agent::AccountToolAdapter.new(assistant, tool_id: 'list_my_appointments')
    expect(JSON.parse(adapter.execute(absent_context))).to eq('success' => false, 'reason' => 'not_found')
  end
end
