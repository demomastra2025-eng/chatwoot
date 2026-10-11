require 'rails_helper'

RSpec.describe Captain::Conversation::PartDeliveryGuard do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:entry) { create(:captain_assistant, account: account) }
  let(:specialist) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, status: :pending) }
  let(:session) { Captain::Conversation::AgentSession.new(entry: entry, conversation: conversation) }

  before do
    create(:captain_inbox, inbox: inbox, captain_assistant: entry)
    session.change do |data|
      data['parts'] = [{ 'id' => 'synthetic-part', 'version' => 1,
                         'executor_agent_id' => specialist.id, 'state' => 'answered' }]
    end
  end

  it 'survives an owner change but rejects a changed part version' do
    session.update_routing(actor_id: specialist.id)
    session.update_routing(actor_id: entry.id)
    expect(described_class.current?(conversation: conversation, assistant: specialist,
                                    part_id: 'synthetic-part', version: 1)).to be(true)

    session.change { |data| data['parts'].first['version'] = 2 }
    expect(described_class.current?(conversation: conversation, assistant: specialist,
                                    part_id: 'synthetic-part', version: 1)).to be(false)
  end

  it 'rejects cancellation before automatic delivery' do
    session.change { |data| data['parts'].first['cancelled'] = true }

    expect(described_class.current?(conversation: conversation, assistant: specialist,
                                    part_id: 'synthetic-part', version: 1)).to be(false)
  end
end
