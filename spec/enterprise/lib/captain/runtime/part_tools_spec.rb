require 'rails_helper'

RSpec.describe Captain::Runtime::PartTools do
  def tool(kind)
    kind.allocate
  end

  let(:withheld) do
    [tool(Captain::Tools::HandoffTool), tool(Captain::Tools::ResolveConversationTool), tool(Captain::Tools::CancelResponseTool)]
  end
  let(:booking) { double('create_appointment', name: 'create_appointment', metadata: { risk_level: 'high', idempotent: false }) }
  let(:lookup) { double('faq_lookup', name: 'faq_lookup', metadata: { read_only: true, risk_level: 'low' }) }
  let(:custom) { double('custom_http_tool', name: 'custom_http_tool') }

  it 'withholds the three tools that change who controls the conversation, by class' do
    withheld.each { |item| expect(described_class.allowed?(item)).to be(false) }
  end

  it 'allows every other tool, mutating or read-only, also an HTTP or MCP wrapper' do
    [booking, lookup, custom].each { |item| expect(described_class.allowed?(item)).to be(true) }
  end

  it 'filters a tool list and keeps its order' do
    expect(described_class.filter([booking, *withheld, lookup, custom])).to eq([booking, lookup, custom])
    expect(described_class.filter(nil)).to eq([])
  end

  it 'lists the registry ids of the withheld tools, for the prompt of a part' do
    expect(described_class.withheld_tool_ids).to contain_exactly('handoff', 'resolve_conversation', 'cancel_response')
  end

  it 'keeps the shared read tools of the owner in a part: the FAQ and the service catalog, never the handoff' do
    account = create(:account)
    account.enable_features!('scheduling')
    owner = create(:captain_assistant, account: account)
    owner.update!(config: { 'tool_access' => { 'agent' => { 'enabled' => true, 'tool_ids' => ['handoff'] } } })

    tools = owner.agent.tools
    names = described_class.filter(tools).map(&:name)

    expect(tools.map(&:name)).to include('handoff')
    expect(names).to include('faq_lookup', 'search_scheduling_services')
    expect(names).not_to include('handoff')
    expect(names).to eq(names.uniq)
  end

  it 'does not decide by name: a renamed control tool is still withheld' do
    renamed = tool(Captain::Tools::HandoffTool)
    allow(renamed).to receive(:name).and_return('escalate_to_person')

    expect(described_class.allowed?(renamed)).to be(false)
  end
end
