require 'rails_helper'

RSpec.describe Captain::Runtime::PartRegistry do
  let(:context) do
    { state: { assistant_id: 1 }, agent_graph: [{ id: 1 }, { id: 2 }],
      agent_request_id: 'synthetic-request', parts: [] }
  end

  def plan(parts, mode: 'answer_myself', clarification: nil)
    described_class.new(context).accept!(mode: mode, parts: parts, clarification: clarification)
  end

  def next_message
    context.delete(:part_plan_accepted)
    context.delete(:part_plan)
    context.delete(:active_part_id)
    context.delete(:active_part_version)
  end

  describe '.planning_available?' do
    it 'is available only when the channel holds an agent other than the current one' do
      expect(described_class.planning_available?(context)).to be(true)
      expect(described_class.planning_available?(context.merge(state: { assistant_id: 2 }))).to be(true)
      expect(described_class.planning_available?(context.merge(agent_graph: [{ id: 1 }]))).to be(false)
      expect(described_class.planning_available?(context.merge(agent_graph: []))).to be(false)
      expect(described_class.planning_available?(context.except(:agent_graph))).to be(false)
    end
  end

  describe 'part numbers' do
    let(:stored) { [{ 'id' => 'first-uuid' }, { 'id' => 'second-uuid' }, { 'id' => 'third-uuid' }] }

    it 'numbers a part by its place among the stored parts, from 1, and knows no number for a part that is not stored' do
      expect(%w[first-uuid second-uuid third-uuid].map { |id| described_class.number_of(stored, id) }).to eq([1, 2, 3])
      expect(described_class.number_of(stored, 'gone')).to be_nil
      expect(described_class.number_of(nil, 'first-uuid')).to be_nil
    end

    it 'turns the number the model writes (2, "2" or "#2") into the exact id, and leaves an exact id as it is' do
      expect([2, '2', ' #2 '].map { |reference| described_class.part_id_for(stored, reference) }).to eq(['second-uuid'] * 3)
      expect(described_class.part_id_for(stored, 'third-uuid')).to eq('third-uuid')
    end

    it 'returns a number that points at no stored part as it was written, so the plan is refused as not open' do
      expect(%w[0 4 #0].map { |reference| described_class.part_id_for(stored, reference) }).to eq(%w[0 4 #0])
      expect(described_class.part_id_for(nil, '1')).to eq('1')
    end
  end

  describe '.awaiting_peer_answer?' do
    let(:question) { 'На какое время вас записать?' }
    let(:waiting) do
      { 'id' => 'p', 'state' => 'waiting_customer', 'executor_agent_id' => 2, 'delivered' => [{ 'message_id' => 5, 'content' => question }] }
    end
    let(:history) { [{ role: 'user', content: 'Запишите меня' }, { role: 'assistant', content: question }] }

    it 'is true when the last thing the customer was told is the question of a waiting part of another agent' do
      expect(described_class.awaiting_peer_answer?(context.merge(parts: [waiting], conversation_history: history))).to be(true)
    end

    it 'reads the reply out of the stored form of an assistant message' do
      stored = [{ role: 'assistant', content: JSON.generate(response: question, reasoning: '') }]

      expect(described_class.awaiting_peer_answer?(context.merge(parts: [waiting], conversation_history: stored))).to be(true)
    end

    it 'reads only the deliveries of the current version: the question of an earlier version is not the one just asked' do
      earlier = waiting.merge('version' => 2, 'delivered' => [{ 'message_id' => 5, 'content' => question, 'version' => 1 }])

      expect(described_class.awaiting_peer_answer?(context.merge(parts: [earlier], conversation_history: history))).to be(false)
    end

    it 'is false for the part of the current agent, for a part that does not wait, and when something else was said last' do
      expect(described_class.awaiting_peer_answer?(context.merge(parts: [waiting.merge('executor_agent_id' => 1)], conversation_history: history))).to be(false)
      expect(described_class.awaiting_peer_answer?(context.merge(parts: [waiting.merge('state' => 'done')], conversation_history: history))).to be(false)
      expect(described_class.awaiting_peer_answer?(context.merge(parts: [waiting], conversation_history: history + [{ role: 'assistant', content: 'Другое' }]))).to be(false)
      expect(described_class.awaiting_peer_answer?(context.merge(parts: [waiting], conversation_history: []))).to be(false)
      expect(described_class.awaiting_peer_answer?(context.merge(parts: [], conversation_history: history))).to be(false)
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

    it 'counts a delivery written before versions were recorded for the version it belongs to' do
      parts = [{ 'id' => 'old', 'version' => 1, 'acted' => true, 'delivered' => [{ 'message_id' => 1 }] }]

      expect(described_class.undelivered_outcomes(parts)).to be_empty
    end
  end

  describe '.deliveries_of_version' do
    it 'keeps only what was sent for the current version of the part' do
      part = { 'version' => 2, 'delivered' => [{ 'message_id' => 1, 'version' => 1 }, { 'message_id' => 2, 'version' => 2 }] }

      expect(described_class.deliveries_of_version(part).pluck('message_id')).to eq([2])
      expect(described_class.deliveries_of_version({})).to eq([])
    end
  end

  it 'validates the channel and allows at most three council parts' do
    invalid = [{ fragment: 'One', executor_agent_id: 3 }]
    expect { plan(invalid) }.to raise_error(ArgumentError, /unavailable/)
    four = Array.new(4) { |index| { fragment: "Part #{index}", executor_agent_id: index.even? ? 1 : 2 } }
    expect { plan(four, mode: 'council') }.to raise_error(ArgumentError, /one to three/)
  end

  it 'accepts a verified answer with one simple part in the plan call' do
    accepted = described_class.new(context).accept!(
      mode: 'answer_myself', parts: [{ fragment: 'Режим работы', executor_agent_id: 1 }],
      answer: 'Сегодня до 18:00.'
    )

    expect(accepted[:answer]).to eq('Сегодня до 18:00.')
    expect(accepted[:parts].sole['executor_agent_id']).to eq(1)
  end

  it 'starts a part with nothing recorded about its outcome' do
    part = plan([{ fragment: 'Visit', executor_agent_id: 1 }])[:parts].sole

    expect(part).to include('version' => 1, 'state' => 'open', 'missing_fields' => [], 'summary' => nil, 'acted' => false,
                            'prior_summary' => nil, 'prior_questions' => [], 'prior_acted' => false)
    expect(part).not_to have_key('proposed_operation')
  end

  it 'links an answer to one open part and also creates a separately declared new part' do
    old = plan([{ fragment: 'Visit', executor_agent_id: 1 }])[:parts].sole
    next_message
    current = plan([
      { fragment: 'Tomorrow', executor_agent_id: 1, link_part_id: old['id'], link_action: 'answer' },
      { fragment: 'Price', executor_agent_id: 1, link_action: 'new' }
    ])[:parts]

    expect(current.first).to include('id' => old['id'], 'version' => 2)
    expect(current.last['id']).not_to eq(old['id'])
    expect(context[:parts].size).to eq(2)
  end

  it 'requires an explicit new request when an older part remains open' do
    plan([{ fragment: 'Visit', executor_agent_id: 1 }])
    next_message

    expect { plan([{ fragment: 'Tomorrow', executor_agent_id: 1 }]) }.to raise_error(ArgumentError, /link an open part/)
    expect(plan([{ fragment: 'Tomorrow', executor_agent_id: 1 }], mode: 'clarify',
                clarification: 'К какому запросу относится ответ?')[:mode]).to eq('clarify')
  end

  describe 'a continuation: the answer of the customer to an open part of another agent' do
    let(:question) { 'На какое время вас записать?' }
    let!(:old) do
      part = plan([{ fragment: 'Запишите к терапевту', executor_agent_id: 2 }, { fragment: 'Цена', executor_agent_id: 1 }], mode: 'council')[:parts].first
      described_class.new(context).record_result!(part['id'], state: 'waiting_customer', summary: question, missing_fields: [question])
      next_message
      context[:parts].find { |item| item['id'] == part['id'] }
    end

    def continue(mode: 'council', **attributes)
      plan([{ fragment: 'Давайте в 11', executor_agent_id: 2, link_part_id: old['id'], link_action: 'answer' }.merge(attributes)], mode: mode)
    end

    it 'is a council of that one linked part, run by its owner again as the next version' do
      accepted = continue

      expect(accepted[:mode]).to eq('council')
      expect(accepted[:parts].sole).to include('id' => old['id'], 'version' => 2, 'executor_agent_id' => 2, 'link_action' => 'answer',
                                               'state' => 'open', 'acted' => false, 'summary' => nil,
                                               'prior_summary' => question, 'prior_questions' => [question], 'prior_acted' => false)
    end

    it 'does not give the acting agent the scope of the part: the conversation does not change hands' do
      continue

      expect(context).not_to have_key(:active_part_id)
      expect(context.dig(:state, :captain_response_fence)).to be_nil
    end

    it 'keeps the owner recorded on the part, whatever agent the model names' do
      accepted = continue(executor_agent_id: 1)

      expect(accepted[:parts].sole['executor_agent_id']).to eq(2)
    end

    it 'rejects a council of one new part' do
      expect do
        plan([{ fragment: 'Цена', executor_agent_id: 2, link_action: 'new' }], mode: 'council')
      end.to raise_error(ArgumentError, 'Council needs at least two agents')
    end

    it 'rejects the own-part mode for a part of another agent and names the council' do
      expect { continue(mode: 'answer_myself') }.to raise_error(ArgumentError, /This part belongs to another agent.*mode council and ONLY that part linked/)
    end

    it 'takes the former link action confirmation as an answer, also when the part never proposed anything' do
      accepted = continue(link_action: 'confirmation')

      expect(accepted[:parts].sole).to include('id' => old['id'], 'version' => 2, 'link_action' => 'answer')
    end

    it 'turns the cancellation of a part that already acted into a correction, so that its owner undoes the action' do
      described_class.new(context).record_result!(old['id'], state: 'waiting_customer', acted: true, summary: 'Вы записаны на 10:00.')

      part = continue(link_action: 'cancellation')[:parts].sole

      expect(part).to include('link_action' => 'correction', 'cancelled' => false, 'state' => 'open', 'prior_acted' => true,
                              'prior_summary' => 'Вы записаны на 10:00.')
    end

    it 'keeps the cancellation of a part that never acted' do
      part = continue(link_action: 'cancellation')[:parts].sole

      expect(part).to include('link_action' => 'cancellation', 'cancelled' => true, 'state' => 'done')
    end

    it 'remembers that an earlier version acted' do
      registry = described_class.new(context)
      registry.record_result!(old['id'], state: 'waiting_customer', acted: true)
      next_message
      second = continue[:parts].sole
      registry.record_result!(second['id'], state: 'waiting_customer')
      next_message

      third = plan([{ fragment: 'Ещё', executor_agent_id: 2, link_part_id: old['id'], link_action: 'answer' }], mode: 'council')[:parts].sole

      expect(third).to include('version' => 3, 'prior_acted' => true)
    end
  end

  it 'links a new dependent part to the part planned right before it and keeps that link in the next version' do
    first, second = plan([{ fragment: 'Отменить визит', executor_agent_id: 1 },
                          { fragment: 'Записать на другое время', executor_agent_id: 1, relation: 'depends_on' }])[:parts]
    next_message
    again = plan([{ fragment: 'Да', executor_agent_id: 1, link_part_id: second['id'], link_action: 'answer' },
                  { fragment: 'Да', executor_agent_id: 1, link_part_id: first['id'], link_action: 'answer' }])[:parts]

    expect(first).not_to have_key('depends_on_part_id')
    expect(second['depends_on_part_id']).to eq(first['id'])
    expect(again.first).to include('id' => second['id'], 'version' => 2, 'depends_on_part_id' => first['id'])
  end

  it 'links a conditional part to the part before it too, and no part without a part before it' do
    lone = plan([{ fragment: 'Записать после отмены', executor_agent_id: 1, relation: 'depends_on' }])[:parts].sole
    next_message
    first, conditional = plan([{ fragment: 'Записать на пятницу', executor_agent_id: 1, link_action: 'new' },
                               { fragment: 'Если нет, на субботу', executor_agent_id: 1, relation: 'conditional', link_action: 'new' }])[:parts]

    expect(lone).not_to have_key('depends_on_part_id')
    expect(conditional['depends_on_part_id']).to eq(first['id'])
  end

  it 'persists a part across messages and an agent ownership change' do
    entry = create(:captain_assistant)
    specialist = create(:captain_assistant, account: entry.account)
    conversation = create(:conversation, account: entry.account)
    session = Captain::Conversation::AgentSession.new(entry: entry, conversation: conversation)
    first_context = { state: { assistant_id: entry.id }, agent_graph: [{ id: entry.id }, { id: specialist.id }],
                      agent_session: session, agent_request_id: 'first', parts: [] }
    first = described_class.new(first_context).accept!(
      mode: 'answer_myself', parts: [{ fragment: 'Запись', executor_agent_id: entry.id }]
    )[:parts].sole
    session.update_routing(actor_id: specialist.id)
    next_context = { state: { assistant_id: specialist.id }, agent_graph: first_context[:agent_graph],
                     agent_session: session, agent_request_id: 'second', parts: session.read['parts'] }
    linked = described_class.new(next_context).accept!(
      mode: 'council', parts: [{ fragment: 'Ответ', executor_agent_id: specialist.id,
                                 link_part_id: first['id'], link_action: 'answer' }]
    )[:parts].sole

    expect(linked).to include('id' => first['id'], 'version' => 2, 'executor_agent_id' => entry.id)
    expect(session.read['parts'].sole['version']).to eq(2)
  end

  it 'keeps a completed operation receipt for its part' do
    entry = create(:captain_assistant)
    session = Captain::Conversation::AgentSession.new(entry: entry)
    session.change do |data|
      data['parts'] = [{ 'id' => 'synthetic-part', 'version' => 1,
                         'executor_agent_id' => entry.id, 'state' => 'open' }]
    end
    scope = 'part:synthetic-part:v1'
    first_status, key = session.reserve_operation(scope: scope, tool: 'create_appointment',
                                                  arguments: { slot_id: 9 }, actor_id: entry.id)
    session.finish_operation(key, Captain::ToolResult.success(data: { appointment_id: 77 }))
    second_status, receipt = session.reserve_operation(scope: scope, tool: 'create_appointment',
                                                       arguments: { slot_id: 9 }, actor_id: entry.id)

    expect(first_status).to eq(:reserved)
    expect(second_status).to eq(:existing)
    expect(receipt['status']).to eq('finished')
  end

  it 'has no handoff mode: a transfer to one colleague is that colleague\'s own tool, not a plan' do
    expect(described_class::MODES).to eq(%w[answer_myself council clarify])
    expect { plan([{ fragment: 'Book', executor_agent_id: 2 }], mode: 'handoff') }.to raise_error(ArgumentError, 'Invalid request mode')
  end

  it 'has no link action confirmation and no state that waits for one' do
    expect(described_class::LINK_ACTIONS).to eq(%w[new answer correction cancellation])
    expect(described_class::STATES).not_to include('waiting_confirmation')
    expect(described_class::OPEN_STATES).to eq(%w[open waiting_customer unknown])
  end

  it 'turns the parts through the given block only for a new plan and replays a saved plan as it was' do
    entry = create(:captain_assistant)
    session = Captain::Conversation::AgentSession.new(entry: entry)
    registry_context = { state: { assistant_id: entry.id }, agent_graph: [{ id: entry.id }], agent_session: session,
                         agent_request_id: 'once', parts: [] }
    turned = []
    block = lambda do |items|
      turned << items
      items.map { |item| item.merge(executor_agent_id: entry.id) }
    end

    first = described_class.new(registry_context).accept!(mode: 'answer_myself', parts: [{ fragment: 'Адрес' }], &block)
    replay_context = registry_context.merge(parts: session.read['parts'])
    replay_context.delete(:part_plan_accepted)
    replayed = described_class.new(replay_context).accept!(mode: 'answer_myself', parts: [{ fragment: 'Другое' }], &block)

    expect(first[:parts].sole).to include('executor_agent_id' => entry.id, 'fragment' => 'Адрес')
    expect(replayed[:parts].sole['fragment']).to eq('Адрес')
    expect(turned).to eq([[{ fragment: 'Адрес' }]])
  end

  describe '#record_result!' do
    let(:part) { plan([{ fragment: 'Запись', executor_agent_id: 1 }])[:parts].sole }

    it 'stores only the keys it is given, in the stored part, and caps the summary' do
      registry = described_class.new(context)
      registry.record_result!(part['id'], state: 'done', summary: 'x' * 700, missing_fields: [], acted: true)

      expect(context[:parts].sole).to include('state' => 'done', 'acted' => true, 'missing_fields' => [], 'fragment' => 'Запись',
                                              'executor_agent_id' => 1)
      expect(context[:parts].sole['summary'].size).to eq(described_class::SUMMARY_LIMIT)

      registry.record_result!(part['id'], state: 'answered')

      expect(context[:parts].sole).to include('state' => 'answered', 'acted' => true)
      expect(context[:parts].sole['summary'].size).to eq(described_class::SUMMARY_LIMIT)
    end

    it 'stores the sentence told to the customer apart from the summary, and the failure that stopped the part by names and codes' do
      registry = described_class.new(context)
      failure = { 'tool' => 'create_appointment', 'kind' => 'technical', 'reason' => 'provider_unavailable' }

      registry.record_result!(part['id'], state: 'done', summary: 'create_appointment: {"id":7}', reply_text: 'Вы записаны.',
                                          acted: true, technical: failure)

      expect(context[:parts].sole).to include('summary' => 'create_appointment: {"id":7}', 'reply_text' => 'Вы записаны.',
                                              'technical' => failure)
      registry.record_result!(part['id'], state: 'done', reply_text: 'x' * (described_class::REPLY_TEXT_LIMIT + 10))
      expect(context[:parts].sole['reply_text'].size).to eq(described_class::REPLY_TEXT_LIMIT)
      expect(context[:parts].sole['technical']).to eq(failure)
    end

    it 'starts a new version of a part without the reply text and the failure of the one before' do
      stored = part
      described_class.new(context).record_result!(stored['id'], state: 'waiting_customer', reply_text: 'Когда?',
                                                                technical: { 'reason' => 'invalid_output' })
      next_message

      second = plan([{ fragment: 'в 11', executor_agent_id: 1, link_part_id: stored['id'], link_action: 'answer' }]).fetch(:parts).first

      expect(second).to include('id' => stored['id'], 'version' => 2)
      expect(second).not_to include('reply_text', 'technical')
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
          mode: 'council', parts: [{ fragment: 'Цена', executor_agent_id: specialist.id }, { fragment: 'Запись', executor_agent_id: entry.id }]
        )[:parts].first
      end

      it 'goes straight to the session, without the parts or the graph of the run, and does not clobber what was delivered meanwhile' do
        stored
        session.change { |data| data['parts'].first['delivered'] = [{ 'message_id' => 3, 'content' => 'x' }] }
        bare = { agent_session: session }

        described_class.new(bare).record_result!(stored['id'], state: 'done', summary: 'Готово', acted: true)

        saved = session.read['parts'].first
        expect(saved).to include('state' => 'done', 'summary' => 'Готово', 'acted' => true, 'delivered' => [{ 'message_id' => 3, 'content' => 'x' }])
        expect(bare[:parts].first).to include('state' => 'done')
      end

      it 'works when the run is no longer current: a booking that happened must be on record' do
        stored
        conversation.update!(status: :open)

        described_class.new(session_context).record_result!(stored['id'], state: 'done', acted: true)

        expect(session.read['parts'].first).to include('state' => 'done', 'acted' => true)
      end

      it 'can move the part to another owner' do
        described_class.new(session_context).record_result!(stored['id'], state: 'open', executor_agent_id: entry.id)

        expect(session.read['parts'].first['executor_agent_id']).to eq(entry.id)
      end
    end
  end
end
