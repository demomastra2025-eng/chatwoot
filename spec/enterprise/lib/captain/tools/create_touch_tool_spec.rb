require 'rails_helper'

RSpec.describe Captain::Tools::CreateTouchTool, type: :model do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:tool) { described_class.new(assistant) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let(:tool_context) { Struct.new(:state).new({ conversation: { id: conversation.id }, contact: { id: contact.id } }) }

  it 'returns normalized create_touch payload' do
    payload = JSON.parse(tool.perform(tool_context, body: 'Ping client tomorrow', scheduled_at: 2.days.from_now.iso8601))

    expect(payload).to include('action' => 'create_touch')
    expect(payload['touch']).to include('body' => 'Ping client tomorrow', 'status' => 'pending')
  end
end
