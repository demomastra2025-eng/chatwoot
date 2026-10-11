require 'rails_helper'

RSpec.describe Captain::AgentChannel, type: :model do
  let(:account) { create(:account) }
  let(:agent) { create(:captain_assistant, account: account, channel_scope: 'selected') }
  let(:inbox) { create(:inbox, account: account) }

  it 'uses explicit membership only for selected active external agents' do
    expect(agent.works_on_inbox?(inbox)).to be false
    described_class.create!(account: account, assistant: agent, inbox: inbox)
    expect(agent.works_on_inbox?(inbox)).to be true
    agent.update!(active: false)
    expect(agent.works_on_inbox?(inbox)).to be false
  end

  it 'does not admit foreign channels or duplicate selections' do
    expect(described_class.new(account: account, assistant: agent, inbox: create(:inbox))).not_to be_valid
    described_class.create!(account: account, assistant: agent, inbox: inbox)
    expect(described_class.new(account: account, assistant: agent, inbox: inbox)).not_to be_valid
  end

  it 'keeps voice inboxes outside text channel membership' do
    voice = create(:inbox, account: account, channel: build(:channel_voice, account: account))
    expect(described_class.new(account: account, assistant: agent, inbox: voice)).not_to be_valid
    agent.update!(channel_scope: 'all')
    expect(agent.works_on_inbox?(voice)).to be false
  end
end
