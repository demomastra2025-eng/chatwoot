# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Runtime::TurnDispatcher do
  let(:account) { create(:account) }
  let(:tool_config) { { 'tool_access' => { 'agent' => { 'enabled' => true, 'tool_ids' => %w[create_appointment handoff] } } } }
  let!(:doctors) { create(:captain_assistant, account: account, routing_description: 'Запись к ЛОР-врачам', config: tool_config) }
  let!(:procedures) { create(:captain_assistant, account: account, routing_description: 'ЛОР-процедуры', config: tool_config) }
  let!(:surgery) { create(:captain_assistant, account: account, routing_description: 'ЛОР-операции', config: tool_config) }
  let(:conversation) { create(:conversation, account: account) }
  let(:run_context) { Captain::AgentRunContext.new(entry: doctors, conversation: conversation) }
  let(:session) { Captain::Conversation::AgentSession.new(entry: doctors, conversation: conversation) }
  let(:context) do
    run_context.prepare({ state: { account_id: account.id, assistant_id: doctors.id }, conversation_history: [],
                          captain_v2_current_input: 'Хочу к ЛОРу и аудиометрию', agent_request_id: 'req-1' })
  end
  let(:events) { [] }

  after { Current.executed_by = nil }

  around do |example|
    subscriber = ActiveSupport::Notifications.subscribe(/\Acaptain\.agent\./) { |name, *, payload| events << [name, payload] }
    example.run
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  def decision(key, kind, ids)
    Captain::Runtime::DecisionRouter::Decision.new(key: key, kind: kind, agent_ids: ids)
  end

  def dispatcher(decision, snapshot: nil)
    described_class.new(graph: run_context.graph, run_context: run_context, account: account,
                        routing: { decision: decision, snapshot: snapshot, request_id: 'routing-1' })
  end

  describe 'a route to one agent' do
    it 'gives the conversation to the agent with a new routing revision and the trail, and activates it' do
      dispatcher(decision("route_agent_#{procedures.id}", 'agent', [procedures.id])).prepare!(context)

      saved = session.read
      expect(saved['current_assistant_id']).to eq(procedures.id)
      expect(saved['routing_revision']).to eq(1)
      expect(saved['routing_trail']).to eq([{ 'kind' => 'agent', 'to' => [procedures.id] }])
      expect(context[:current_agent]).to eq("assistant_#{procedures.id}")
      expect(context.dig(:state, :assistant_id)).to eq(procedures.id)
      expect(context.dig(:state, :agent_routing_revision)).to eq(1)
      expect(events.map(&:first)).not_to include('captain.agent.transfer')
    end

    it 'records the transfer from the agent that held the conversation' do
      session.update_routing(actor_id: doctors.id)
      dispatcher(decision("route_agent_#{surgery.id}", 'agent', [surgery.id])).prepare!(context)

      expect(session.read['routing_trail'].last).to eq('kind' => 'agent', 'from' => doctors.id, 'to' => [surgery.id])
      transfer = events.find { |name, _| name == 'captain.agent.transfer' }
      expect(transfer.last).to include('from_agent_id' => doctors.id, 'to_agent_id' => surgery.id)
    end

    it 'continues the open questions of the chosen agent in the conversation' do
      session.change do |data|
        data['parts'] = [{ 'id' => 'p1', 'state' => 'waiting_customer', 'executor_agent_id' => procedures.id, 'version' => 1 },
                         { 'id' => 'p2', 'state' => 'waiting_customer', 'executor_agent_id' => surgery.id, 'version' => 1 }]
      end
      dispatcher(decision("route_agent_#{procedures.id}", 'agent', [procedures.id])).prepare!(context)

      states = session.read['parts'].to_h { |part| [part['id'], part['state']] }
      expect(states).to eq('p1' => 'answered', 'p2' => 'waiting_customer')
    end
  end

  it 'keeps the current agent on stay_current and runs it' do
    session.update_routing(actor_id: procedures.id)
    dispatcher(decision('stay_current', 'stay', [procedures.id])).prepare!(context)

    expect(session.read).to include('current_assistant_id' => procedures.id, 'routing_revision' => 1)
    expect(context[:current_agent]).to eq("assistant_#{procedures.id}")
  end

  describe 'a council' do
    let(:snapshot) do
      Captain::Runtime::RoutingSnapshot.new(agents: Captain::Runtime::RoutingSnapshot.agents_for(run_context.graph.candidate_rows),
                                            latest_message: 'Хочу к ЛОРу и аудиометрию', human_available: true)
    end
    let(:council) { decision("council_#{doctors.id}_#{procedures.id}", 'council', [doctors.id, procedures.id]) }

    def split_into(parts, fallback: false)
      splitter = instance_double(Captain::Runtime::CouncilSplitter,
                                 split: Captain::Runtime::CouncilSplitter::Result.new(parts: parts, fallback: fallback))
      allow(Captain::Runtime::CouncilSplitter).to receive(:new).and_return(splitter)
    end

    it 'accepts exactly the participants of the decision in the order of the message, and the first one takes the conversation' do
      split_into([{ 'executor_agent_id' => procedures.id, 'fragment' => 'аудиометрию', 'relation' => 'independent', 'link_action' => 'new' },
                  { 'executor_agent_id' => doctors.id, 'fragment' => 'к ЛОРу', 'relation' => 'depends_on', 'link_action' => 'new' }])

      dispatcher(council, snapshot: snapshot).prepare!(context)

      plan = context[:part_plan]
      expect(plan[:mode]).to eq('council')
      expect(plan[:parts].pluck('executor_agent_id')).to eq([procedures.id, doctors.id])
      expect(plan[:parts].last['depends_on_part_id']).to eq(plan[:parts].first['id'])
      expect(session.read).to include('current_assistant_id' => procedures.id)
      expect(session.read['routing_trail'].last).to eq('kind' => 'council', 'to' => [doctors.id, procedures.id])
      expect(context[:current_agent]).to eq("assistant_#{procedures.id}")
      expect(dispatcher(council)).to be_council
    end

    it 'keeps the current agent when one holds the conversation' do
      session.update_routing(actor_id: surgery.id)
      split_into([{ 'executor_agent_id' => doctors.id, 'fragment' => 'к ЛОРу' },
                  { 'executor_agent_id' => procedures.id, 'fragment' => 'аудиометрию' }])

      dispatcher(council, snapshot: snapshot).prepare!(context)

      expect(session.read['current_assistant_id']).to eq(surgery.id)
      expect(context[:current_agent]).to eq("assistant_#{surgery.id}")
    end

    it 'refuses a split that does not match the participants' do
      split_into([{ 'executor_agent_id' => doctors.id, 'fragment' => 'к ЛОРу' },
                  { 'executor_agent_id' => surgery.id, 'fragment' => 'операция' }])

      expect { dispatcher(council, snapshot: snapshot).prepare!(context) }.to raise_error(described_class::CouncilUnavailable)
    end
  end

  it 'lets the one agent of a channel hold the conversation without a decision' do
    procedures.update!(active: false)
    surgery.update!(active: false)

    dispatcher(nil).prepare!(context)

    expect(session.read['current_assistant_id']).to eq(doctors.id)
    expect(context[:current_agent]).to eq("assistant_#{doctors.id}")
  end

  it 'writes nothing into the conversation for a reply suggestion' do
    suggestion = Captain::AgentRunContext.new(entry: doctors, conversation: conversation, ephemeral_session: true)
    suggestion_context = suggestion.prepare({ state: { account_id: account.id, assistant_id: doctors.id, source: 'reply_suggestion' },
                                              conversation_history: [] })
    described_class.new(graph: suggestion.graph, run_context: suggestion, account: account,
                        routing: { decision: decision("route_agent_#{surgery.id}", 'agent', [surgery.id]) }).prepare!(suggestion_context)

    expect(conversation.reload.additional_attributes.to_h).not_to have_key(Captain::Conversation::AgentSession::ATTRIBUTE)
    expect(suggestion_context[:current_agent]).to eq("assistant_#{surgery.id}")
  end
end
