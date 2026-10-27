require 'rails_helper'

# A reply suggestion answers a booking question with one call (search_booking_options), so the agent of a suggestion that searches
# free times gets that search next to its own tools. The conversation and the Playground keep the tools the clinic selected.
RSpec.describe Captain::Assistant do
  let(:account) { create(:account) }
  let(:tool_ids) { %w[search_available_slots search_scheduling_resources] }
  let(:assistant) do
    create(:captain_assistant, account: account,
                               config: { 'tool_access' => { 'agent' => { 'enabled' => true, 'tool_ids' => tool_ids } } })
  end

  before { account.enable_features!('scheduling') }

  def names(agent)
    agent.tools.map(&:name)
  end

  it 'adds the booking search to the tools of a suggestion run of an agent that searches free times' do
    agent = assistant.agent(suggestion_tools: true)

    expect(names(agent)).to include('search_available_slots', 'search_booking_options')
    expect(agent.tools.find { |tool| tool.name == 'search_booking_options' }).to be_a(Captain::Tools::Agent::AccountToolAdapter)
  end

  it 'leaves the tools of every other run as the clinic selected them' do
    expect(names(assistant.agent)).not_to include('search_booking_options')
    expect(names(assistant.agent(read_only_tools: true))).not_to include('search_booking_options')
    expect(assistant.selected_agent_tool_ids).not_to include('search_booking_options')
  end

  context 'when the agent has no free-time search' do
    let(:tool_ids) { %w[search_scheduling_resources] }

    it 'does not give it the booking search, which lists free times' do
      expect(names(assistant.agent(suggestion_tools: true))).not_to include('search_booking_options')
    end
  end

  it 'is a tool of the patient agent only: staff and Copilot do not get it' do
    expect(Captain::ToolRegistry.definition_for('search_booking_options').allowed_scopes).to eq([Captain::ToolAccess::SCOPE_AGENT])
  end
end
