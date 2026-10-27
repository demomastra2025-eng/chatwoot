require 'rails_helper'

RSpec.describe Concerns::CaptainAgentRouting, type: :model do
  let(:account) { create(:account) }
  let(:agent) { create(:captain_assistant, account: account) }

  describe '#entry_eligible?' do
    it 'is true for an enabled external agent, whichever agent it is: every agent is a peer' do
      other = create(:captain_assistant, account: account)

      expect(agent).to be_entry_eligible
      expect(other).to be_entry_eligible
    end

    it 'is false for an agent that is switched off or is not an external agent' do
      expect(create(:captain_assistant, account: account, active: false)).not_to be_entry_eligible
      expect(create(:captain_assistant, account: account, usage_mode: 'internal_assistant')).not_to be_entry_eligible
    end
  end

  describe '.entry_eligible' do
    it 'lists the enabled external agents of every workspace and nothing else' do
      other_workspace = create(:captain_assistant)
      create(:captain_assistant, account: account, active: false)
      create(:captain_assistant, account: account, usage_mode: 'internal_assistant')

      expect(Captain::Assistant.entry_eligible.where(account_id: [account.id, other_workspace.account_id])).to contain_exactly(agent, other_workspace)
    end
  end

  describe 'the agent card (routing_description)' do
    it 'is optional' do
      agent.routing_description = nil

      expect(agent).to be_valid
    end

    it 'is limited in length' do
      agent.routing_description = 'a' * (described_class::ROUTING_DESCRIPTION_MAX_LENGTH + 1)

      expect(agent).not_to be_valid
      expect(agent.errors[:routing_description]).to be_present
    end
  end

  it 'has no per-agent routing graph: no allowed targets, no channel peers' do
    expect(agent).not_to respond_to(:handoff_agent_ids)
    expect(agent).not_to respond_to(:handoff_targets)
    expect(agent).not_to respond_to(:channel_peers)
    expect(agent).not_to respond_to(:main_in_inbox_ids)
  end

  it 'lets any agent be switched off, the last one included' do
    agent
    other = create(:captain_assistant, account: account)

    expect(other.update(active: false)).to be(true)
    expect(agent.update(active: false)).to be(true)
    expect(account.captain_assistants.entry_eligible).to be_empty
  end
end
