require 'rails_helper'

RSpec.describe Captain::Runtime::PartRegistry do
  let(:context) do
    { state: { assistant_id: 1 }, agent_graph: [{ id: 1 }, { id: 2 }, { id: 3 }], agent_request_id: 'synthetic-request', parts: [] }
  end

  # A council of the router: one part per participant, executor ids set, in the order of the message.
  def plan(parts, &)
    described_class.new(context).accept!(mode: 'council', parts: parts, &)
  end

  def next_message
    context.delete(:part_plan_accepted)
    context.delete(:part_plan)
    context[:agent_request_id] = SecureRandom.uuid
  end

  describe 'part numbers' do
    let(:stored) { [{ 'id' => 'first-uuid' }, { 'id' => 'second-uuid' }, { 'id' => 'third-uuid' }] }

    it 'numbers a part by its place among the stored parts, from 1, and knows no number for a part that is not stored' do
      expect(%w[first-uuid second-uuid third-uuid].map { |id| described_class.number_of(stored, id) }).to eq([1, 2, 3])
      expect(described_class.number_of(stored, 'gone')).to be_nil
      expect(described_class.number_of(nil, 'first-uuid')).to be_nil
    end

    it 'turns a number (2, "2" or "#2") into the exact id, and leaves an exact id as it is' do
      expect([2, '2', ' #2 '].map { |reference| described_class.part_id_for(stored, reference) }).to eq(['second-uuid'] * 3)
      expect(described_class.part_id_for(stored, 'third-uuid')).to eq('third-uuid')
      expect(%w[0 4 #0].map { |reference| described_class.part_id_for(stored, reference) }).to eq(%w[0 4 #0])
    end
  end

  describe '.undelivered_outcomes' do
    it 'lists the parts that acted and were never reported to the customer' do
      parts = [{ 'id' => 'a', 'acted' => true, 'delivered' => [] }, { 'id' => 'b', 'acted' => true, 'delivered' => [{ 'message_id' => 1 }] },
               { 'id' => 'c', 'acted' => false, 'delivered' => [] }, { 'id' => 'd', 'acted' => true, 'cancelled' => true }, { 'id' => 'e', 'acted' => true }]

      expect(described_class.undelivered_outcomes(parts).pluck('id')).to eq(%w[a e])
      expect(described_class.undelivered_outcomes(nil)).to eq([])
    end

    it 'reports the action of a follow-up version whose reply was dropped, not hidden by the question an earlier version delivered' do
      question = { 'message_id' => 1, 'content' => 'На какое время?', 'version' => 1 }
      parts = [{ 'id' => 'dropped', 'version' => 2, 'acted' => true, 'delivered' => [question] },
               { 'id' => 'told', 'version' => 2, 'acted' => true, 'delivered' => [question, { 'message_id' => 2, 'version' => 2 }] },
               { 'id' => 'first', 'version' => 1, 'acted' => true, 'delivered' => [question] }]

      expect(described_class.undelivered_outcomes(parts).pluck('id')).to eq(['dropped'])
    end
  end

  describe '#accept!' do
    it 'stores a council of two or three parts of the agents of the turn, each part new and open' do
      parts = plan([{ 'executor_agent_id' => 2, 'fragment' => 'аудиометрия' }, { 'executor_agent_id' => 1, 'fragment' => 'к ЛОРу' }])[:parts]

      expect(parts.pluck('executor_agent_id')).to eq([2, 1])
      expect(parts.first).to include('version' => 1, 'state' => 'open', 'link_action' => 'new', 'acted' => false, 'patient' => 'unknown',
                                     'relation' => 'independent')
      expect(context[:part_plan_accepted]).to be(true)
      expect(context[:part_plan][:mode]).to eq('council')
    end

    it 'refuses another mode, no part, more than three parts and an agent that is not an agent of the turn' do
      expect { described_class.new(context).accept!(mode: 'clarify', parts: []) }.to raise_error(ArgumentError, 'Invalid plan mode')
      expect { plan([]) }.to raise_error(ArgumentError, /one to three parts/)
      expect { plan((1..4).map { |id| { 'executor_agent_id' => (id % 3) + 1, 'fragment' => 'x' } }) }.to raise_error(ArgumentError)
      expect { plan([{ 'executor_agent_id' => 1, 'fragment' => 'x' }, { 'executor_agent_id' => 9, 'fragment' => 'y' }]) }
        .to raise_error(ArgumentError, /not an agent of this turn/)
      expect { plan([{ 'executor_agent_id' => 1, 'fragment' => ' ' }, { 'executor_agent_id' => 2, 'fragment' => 'y' }]) }
        .to raise_error(ArgumentError, /fragment/)
    end

    it 'continues an open part of the same agent as its next version, and takes a link to another agent\'s part as a new part' do
      first = plan([{ 'executor_agent_id' => 1, 'fragment' => 'Запись' }, { 'executor_agent_id' => 2, 'fragment' => 'Цена' }])[:parts]
      described_class.new(context).record_result!(first.first['id'], state: 'waiting_customer', missing_fields: ['Когда?'])
      next_message

      again = plan([{ 'executor_agent_id' => 1, 'fragment' => 'в 11', 'link_part_id' => first.first['id'], 'link_action' => 'answer' },
                    { 'executor_agent_id' => 3, 'fragment' => 'анализы', 'link_part_id' => first.first['id'], 'link_action' => 'answer' }])[:parts]

      expect(again.first).to include('id' => first.first['id'], 'version' => 2, 'link_action' => 'answer', 'prior_questions' => ['Когда?'])
      expect(again.last).to include('version' => 1, 'link_action' => 'new')
      expect(again.last['id']).not_to eq(first.first['id'])
    end

    it 'turns the cancellation of a part that already acted into a correction, and keeps the cancellation of a part that never acted' do
      first = plan([{ 'executor_agent_id' => 1, 'fragment' => 'Запись' }, { 'executor_agent_id' => 2, 'fragment' => 'Цена' }])[:parts]
      described_class.new(context).record_result!(first.first['id'], state: 'waiting_customer', acted: true)
      described_class.new(context).record_result!(first.last['id'], state: 'waiting_customer')
      next_message

      cancel = { 'link_action' => 'cancellation' }
      again = plan([cancel.merge('executor_agent_id' => 1, 'fragment' => 'отмените', 'link_part_id' => first.first['id']),
                    cancel.merge('executor_agent_id' => 2, 'fragment' => 'не надо', 'link_part_id' => first.last['id'])])[:parts]

      expect(again.first).to include('link_action' => 'correction', 'state' => 'open', 'prior_acted' => true)
      expect(again.last).to include('link_action' => 'cancellation', 'state' => 'done', 'cancelled' => true)
    end

    it 'links a new dependent part to the part planned right before it' do
      first, second = plan([{ 'executor_agent_id' => 1, 'fragment' => 'Отменить визит' },
                            { 'executor_agent_id' => 2, 'fragment' => 'Записать на другое время', 'relation' => 'depends_on' }])[:parts]

      expect(first).not_to have_key('depends_on_part_id')
      expect(second['depends_on_part_id']).to eq(first['id'])
    end

    it 'checks the parts with the given block only for a new plan and replays a saved plan as it was' do
      entry = create(:captain_assistant)
      specialist = create(:captain_assistant, account: entry.account)
      session = Captain::Conversation::AgentSession.new(entry: entry)
      registry_context = { state: { assistant_id: entry.id }, agent_graph: [{ id: entry.id }, { id: specialist.id }], agent_session: session,
                           agent_request_id: 'once', parts: [] }
      checked = []
      asked = [{ 'executor_agent_id' => entry.id, 'fragment' => 'Адрес' }, { 'executor_agent_id' => specialist.id, 'fragment' => 'Цена' }]

      first = described_class.new(registry_context).accept!(mode: 'council', parts: asked) do |items|
        checked << items
        items
      end
      replay_context = registry_context.merge(parts: session.read['parts']).except(:part_plan_accepted)
      replayed = described_class.new(replay_context).accept!(mode: 'council', parts: asked.map { |part| part.merge('fragment' => 'Иное') })

      expect(first[:parts].pluck('fragment')).to eq(%w[Адрес Цена])
      expect(replayed[:parts].pluck('fragment')).to eq(%w[Адрес Цена])
      expect(checked).to eq([asked])
    end
  end

  describe '#absorb_open_parts!' do
    it 'closes the open questions of the agent that answers the turn alone, and nothing of the other agents' do
      context[:parts] = [{ 'id' => 'a', 'state' => 'waiting_customer', 'executor_agent_id' => 1 },
                         { 'id' => 'b', 'state' => 'open', 'executor_agent_id' => 1, 'summary' => 'Спросил дату' },
                         { 'id' => 'c', 'state' => 'waiting_customer', 'executor_agent_id' => 2 },
                         { 'id' => 'd', 'state' => 'waiting_customer', 'executor_agent_id' => 1, 'handed_to_staff' => true },
                         { 'id' => 'e', 'state' => 'done', 'executor_agent_id' => 1 }]

      described_class.new(context).absorb_open_parts!(1)

      expect(context[:parts].to_h { |part| [part['id'], part['state']] })
        .to eq('a' => 'answered', 'b' => 'answered', 'c' => 'waiting_customer', 'd' => 'waiting_customer', 'e' => 'done')
      expect(context[:parts].first['summary']).to eq(described_class::ABSORBED_SUMMARY)
      expect(context[:parts].second['summary']).to eq('Спросил дату')
    end
  end

  it 'keeps a completed operation receipt for its part' do
    entry = create(:captain_assistant)
    session = Captain::Conversation::AgentSession.new(entry: entry)
    session.change do |data|
      data['parts'] = [{ 'id' => 'synthetic-part', 'version' => 1, 'executor_agent_id' => entry.id, 'state' => 'open' }]
    end
    scope = 'part:synthetic-part:v1'
    first_status, key = session.reserve_operation(scope: scope, tool: 'create_appointment', arguments: { slot_id: 9 }, actor_id: entry.id,
                                                  peer_part: true)
    session.finish_operation(key, Captain::ToolResult.success(data: { appointment_id: 77 }))
    second_status, receipt = session.reserve_operation(scope: scope, tool: 'create_appointment', arguments: { slot_id: 9 },
                                                       actor_id: entry.id, peer_part: true)

    expect(first_status).to eq(:reserved)
    expect(second_status).to eq(:existing)
    expect(receipt['status']).to eq('finished')
  end

  describe '#record_result!' do
    let(:part) { plan([{ 'executor_agent_id' => 1, 'fragment' => 'Запись' }, { 'executor_agent_id' => 2, 'fragment' => 'Цена' }])[:parts].first }

    it 'stores only the keys it is given, in the stored part, and caps the summary' do
      registry = described_class.new(context)
      registry.record_result!(part['id'], state: 'done', summary: 'x' * 700, missing_fields: [], acted: true)

      expect(context[:parts].first).to include('state' => 'done', 'acted' => true, 'missing_fields' => [], 'fragment' => 'Запись',
                                               'executor_agent_id' => 1)
      expect(context[:parts].first['summary'].size).to eq(described_class::SUMMARY_LIMIT)
    end

    it 'stores the sentence told to the customer apart from the summary, and the failure that stopped the part by names and codes' do
      registry = described_class.new(context)
      failure = { 'tool' => 'create_appointment', 'kind' => 'technical', 'reason' => 'provider_unavailable' }

      registry.record_result!(part['id'], state: 'done', summary: 'create_appointment: {"id":7}', reply_text: 'Вы записаны.',
                                          acted: true, technical: failure)

      expect(context[:parts].first).to include('summary' => 'create_appointment: {"id":7}', 'reply_text' => 'Вы записаны.',
                                               'technical' => failure)
    end

    it 'validates the state and the part, and nothing else' do
      registry = described_class.new(context)

      expect { registry.record_result!(part['id'], state: 'waiting_confirmation') }.to raise_error(ArgumentError, 'Invalid part state')
      expect { registry.record_result!('missing', state: 'done') }.to raise_error(ArgumentError, 'Part not found')
      expect { registry.record_result!(part['id'], executor_agent_id: 99) }.not_to raise_error
    end

    context 'with a durable session' do
      let(:entry) { create(:captain_assistant) }
      let(:specialist) { create(:captain_assistant, account: entry.account) }
      let(:conversation) { create(:conversation, account: entry.account) }
      let(:session) { Captain::Conversation::AgentSession.new(entry: entry, conversation: conversation) }
      let(:session_context) do
        { state: { assistant_id: entry.id }, agent_graph: [{ id: entry.id }, { id: specialist.id }], agent_session: session,
          agent_request_id: 'session', parts: [] }
      end
      let(:stored) do
        described_class.new(session_context).accept!(
          mode: 'council', parts: [{ 'fragment' => 'Цена', 'executor_agent_id' => specialist.id },
                                   { 'fragment' => 'Запись', 'executor_agent_id' => entry.id }]
        )[:parts].first
      end

      it 'goes straight to the session, without the parts or the graph of the run, and does not clobber what was delivered meanwhile' do
        stored
        session.change { |data| data['parts'].first['delivered'] = [{ 'message_id' => 3, 'content' => 'x' }] }
        bare = { agent_session: session }

        described_class.new(bare).record_result!(stored['id'], state: 'done', summary: 'Готово', acted: true)

        saved = session.read['parts'].first
        expect(saved).to include('state' => 'done', 'summary' => 'Готово', 'acted' => true, 'delivered' => [{ 'message_id' => 3, 'content' => 'x' }])
      end

      it 'works when the run is no longer current: a booking that happened must be on record' do
        stored
        conversation.update!(status: :open)

        described_class.new(session_context).record_result!(stored['id'], state: 'done', acted: true)

        expect(session.read['parts'].first).to include('state' => 'done', 'acted' => true)
      end
    end
  end
end
