require 'rails_helper'

RSpec.describe Concerns::CaptainAgentRouting, type: :model do
  let(:account) { create(:account) }
  let(:source) { create(:captain_assistant, account: account) }
  let(:target) { create(:captain_assistant, account: account) }

  it 'stages route edits until a successful settings save' do
    source.handoff_agent_ids = [target.id]

    expect(Captain::AgentHandoff.where(source_assistant_id: source.id)).not_to exist
    source.save!
    expect(source.reload.handoff_agent_ids).to eq([target.id])
    expect(source.handoff_targets).to contain_exactly(target)
  end

  it 'retains dormant configured routes while runtime targets follow the target activity' do
    source.update!(handoff_agent_ids: [target.id])
    target.update!(active: false)

    expect(source.reload.handoff_agent_ids).to eq([target.id])
    expect(source.handoff_targets).to be_empty
    source.update!(name: 'Edited settings', handoff_agent_ids: [target.id])
    target.update!(active: true)
    expect(source.reload.handoff_targets).to contain_exactly(target)
  end

  it 'rejects a newly selected dormant target' do
    target.update!(active: false)
    source.handoff_agent_ids = [target.id]

    expect(source).not_to be_valid
    expect(source.errors[:handoff_agent_ids]).to include('new targets must be active external agents')
  end

  it 'rejects malformed and cross workspace IDs' do
    source.handoff_agent_ids = ['1 trailing text']
    expect(source).not_to be_valid
    source.handoff_agent_ids = [create(:captain_assistant).id]
    expect(source).not_to be_valid
    expect(source.errors[:handoff_agent_ids]).to include('must belong to this workspace')
  end

  it 'keeps the existing graph when the prompt edit fails validation' do
    source.update!(handoff_agent_ids: [target.id])
    source.assign_attributes(description: '', handoff_agent_ids: [])

    expect(source.save).to be(false)
    expect(Captain::Assistant.find(source.id).handoff_agent_ids).to eq([target.id])
  end

  describe '#channel_peers' do
    let(:inbox) { create(:inbox, account: account) }
    let(:other_inbox) { create(:inbox, account: account) }

    def attach(agent, channel)
      Captain::AgentChannel.create!(account: account, inbox: channel, assistant: agent)
    end

    it 'lists the other active agents that work in a channel of the agent, whatever the stored allowed targets say' do
      source.update!(handoff_agent_ids: [])
      target

      expect(source.channel_peers).to eq([target])
      expect(target.channel_peers).to eq([source])
    end

    it 'leaves out the agent itself, switched-off agents and internal assistants' do
      create(:captain_assistant, account: account, active: false)
      create(:captain_assistant, account: account, usage_mode: 'internal_assistant')
      target

      expect(source.channel_peers).to eq([target])
    end

    it 'follows the channel grid for agents that work in selected channels only' do
      first = create(:captain_assistant, account: account, channel_scope: 'selected')
      second = create(:captain_assistant, account: account, channel_scope: 'selected')
      attach(first, inbox)
      attach(second, other_inbox)
      source.update!(channel_scope: 'selected')
      attach(source, inbox)

      expect(source.channel_peers).to eq([first])
      attach(source, other_inbox)
      expect(source.reload.channel_peers).to eq([first, second])
    end

    it 'meets an agent of all channels only when the other works in at least one channel' do
      nowhere = create(:captain_assistant, account: account, channel_scope: 'selected')
      source

      expect(source.channel_peers).to eq([])
      attach(nowhere, inbox)
      expect(source.channel_peers).to eq([nowhere])
      expect(nowhere.channel_peers).to eq([source])
    end

    it 'has no peers for an agent that is switched off or is not an external agent' do
      target
      source.update!(active: false)

      expect(source.channel_peers).to eq([])
    end
  end
end
