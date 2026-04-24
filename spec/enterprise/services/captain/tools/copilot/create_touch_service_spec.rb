require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::CreateTouchService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:service) { described_class.new(assistant, user: user, conversation: conversation) }

  it 'returns a normalized touch payload wrapper' do
    payload = JSON.parse(service.execute(body: 'Ping client tomorrow', scheduled_at: 2.days.from_now.iso8601))

    expect(payload).to include('action' => 'create_touch')
    expect(payload.fetch('touch')).to include(
      'body' => 'Ping client tomorrow',
      'status' => 'pending'
    )
  end
end
