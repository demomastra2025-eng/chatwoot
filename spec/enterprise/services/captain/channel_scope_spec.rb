require 'rails_helper'

RSpec.describe Captain::ChannelScope do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:voice_inbox) { create_voice_inbox(account) }
  let!(:first_agent) { create(:captain_assistant, account: account) }
  let!(:second_agent) { create(:captain_assistant, account: account) }

  describe '.for_conversation and .for_inbox' do
    it 'gives a text inbox the scope of a text channel, with every enabled external agent as a member' do
      scope = described_class.for_conversation(create(:conversation, account: account, inbox: inbox))

      expect(scope).to have_attributes(kind: :text, inbox: inbox, account: account)
      expect(scope).to be_text
      expect(scope.members.map(&:id)).to eq([first_agent.id, second_agent.id])
    end

    it 'gives a voice inbox the agent of the number as its only member' do
      create(:captain_inbox, inbox: voice_inbox, captain_assistant: second_agent)
      scope = described_class.for_inbox(voice_inbox)

      expect(scope).to be_voice
      expect(scope.members).to eq([second_agent])
    end

    it 'leaves a voice number with no row without members' do
      expect(described_class.for_inbox(voice_inbox).members).to be_empty
    end

    it 'leaves out an agent that is switched off, an internal assistant and an agent of another workspace' do
      second_agent.update!(active: false)
      create(:captain_assistant, account: account, usage_mode: 'internal_assistant')
      create(:captain_assistant)

      expect(described_class.for_inbox(inbox).members).to eq([first_agent])
    end

    it 'gives a voice number no member when its own agent is switched off, whatever the other agents do' do
      create(:captain_inbox, inbox: voice_inbox, captain_assistant: second_agent)
      second_agent.update!(active: false)

      expect(described_class.for_inbox(voice_inbox.reload).members).to be_empty
    end
  end

  describe '.for_workspace and .for_playground' do
    it 'tries out the whole AI of the workspace with no channel' do
      scope = described_class.for_playground(account)

      expect(scope).to be_workspace
      expect(scope.inbox).to be_nil
      expect(scope.members.map(&:id)).to eq([first_agent.id, second_agent.id])
      expect(scope.key).to eq("playground:#{account.id}")
    end

    it 'follows the channel that is picked: a text channel gives all agents, a voice number its own agent' do
      create(:captain_inbox, inbox: voice_inbox, captain_assistant: second_agent)

      expect(described_class.for_playground(account, inbox)).to be_text
      expect(described_class.for_playground(account, inbox).members.map(&:id)).to eq([first_agent.id, second_agent.id])
      expect(described_class.for_playground(account, voice_inbox).members).to eq([second_agent])
    end
  end

  describe '#runtime_enabled?' do
    it 'is on for a text channel that is switched on, in a workspace where the AI is on and an agent is enabled' do
      create(:captain_inbox, inbox: inbox, ai_enabled: true)

      expect(described_class.for_inbox(inbox)).to be_runtime_enabled
    end

    it 'is off for a text channel with no row, and for one that is switched off' do
      expect(described_class.for_inbox(inbox)).not_to be_runtime_enabled

      row = create(:captain_inbox, inbox: inbox, ai_enabled: false)
      expect(described_class.for_inbox(inbox)).not_to be_runtime_enabled

      row.update!(ai_enabled: true)
      expect(described_class.for_inbox(inbox)).to be_runtime_enabled
    end

    it 'is off for a text channel when the workspace AI is off' do
      create(:captain_inbox, inbox: inbox, ai_enabled: true)
      Captain::AccountSettings.new(account).update!('routing' => { 'ai_enabled' => false })

      expect(described_class.for_inbox(inbox)).not_to be_runtime_enabled
    end

    it 'stays on while any agent is enabled, and goes off with the last one: no agent is the channel agent' do
      create(:captain_inbox, inbox: inbox, ai_enabled: true)

      first_agent.update!(active: false)
      expect(described_class.for_inbox(inbox)).to be_runtime_enabled
      second_agent.update!(active: false)
      expect(described_class.for_inbox(inbox)).not_to be_runtime_enabled
      first_agent.update!(active: true)
      expect(described_class.for_inbox(inbox)).to be_runtime_enabled
    end

    it 'does not count an internal assistant as an agent' do
      first_agent.update!(usage_mode: 'internal_assistant')
      second_agent.update!(usage_mode: 'internal_assistant')
      create(:captain_inbox, inbox: inbox, ai_enabled: true)

      expect(described_class.for_inbox(inbox)).not_to be_runtime_enabled
    end

    it 'is on for a voice number while its own agent is enabled, and off when that agent is off' do
      create(:captain_inbox, inbox: voice_inbox, captain_assistant: first_agent)

      expect(described_class.for_inbox(voice_inbox)).to be_runtime_enabled
      first_agent.update!(active: false)
      expect(described_class.for_inbox(voice_inbox)).not_to be_runtime_enabled
    end

    it 'is on for the Playground of a workspace with an enabled agent, and off with none or with the workspace AI off' do
      expect(described_class.for_workspace(account)).to be_runtime_enabled

      Captain::AccountSettings.new(account).update!('routing' => { 'ai_enabled' => false })
      expect(described_class.for_workspace(account.reload)).not_to be_runtime_enabled

      Captain::AccountSettings.new(account).update!('routing' => { 'ai_enabled' => true })
      first_agent.update!(active: false)
      second_agent.update!(active: false)
      expect(described_class.for_workspace(account.reload)).not_to be_runtime_enabled
    end
  end
end
