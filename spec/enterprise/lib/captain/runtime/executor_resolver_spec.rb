require 'rails_helper'

RSpec.describe Captain::Runtime::ExecutorResolver do
  let(:graph) do
    [
      { id: 11, key: 'assistant_11', name: 'Администратор', description: 'Запись на приём' },
      { id: 12, key: 'assistant_12', name: 'Қабылдау', description: 'Приём пациентов' },
      { id: 13, key: 'assistant_13', name: 'Лаборатория  Анализы', description: 'Анализы' },
      { id: 14, key: 'assistant_14', name: 'Приём', description: 'Справки' }
    ]
  end
  let(:context) { { state: { assistant_id: 11 }, agent_graph: graph } }
  let(:person_hint) { 'To pass the customer to a person call the handoff tool, not plan_request.' }

  def resolve_ids(executors, mode: 'council')
    parts = executors.map { |executor| { 'fragment' => 'Запрос', 'executor' => executor } }
    described_class.new(context).resolve(parts, mode: mode).pluck('executor_agent_id')
  end

  it 'resolves a peer by its listed name and the own name to the current agent' do
    expect(resolve_ids(%w[Қабылдау Администратор])).to eq([12, 11])
  end

  it 'ignores case, surrounding spaces, repeated spaces and surrounding quotes' do
    variants = ['  қабылдау ', 'ҚАБЫЛДАУ', '«Қабылдау»', '"Қабылдау"', "'қабылдау'", '“Қабылдау”', ' « лаборатория   АНАЛИЗЫ » ']

    expect(resolve_ids(variants)).to eq([12, 12, 12, 12, 12, 12, 13])
  end

  it 'matches Cyrillic names written in a decomposed unicode form' do
    expect(resolve_ids(['Приём'.unicode_normalize(:nfd), 'ПРИЁМ'], mode: 'clarify')).to eq([14, 14])
  end

  it 'takes the current agent for an omitted or blank executor, also next to a named peer' do
    parts = [{ 'fragment' => 'Свой запрос' }, { 'fragment' => 'Чужой', 'executor' => 'Қабылдау' },
             { 'fragment' => 'Пустой', 'executor' => '  ' }, { 'fragment' => 'Null', 'executor' => nil }]

    resolved = described_class.new(context).resolve(parts, mode: 'council')

    expect(resolved.pluck('executor_agent_id')).to eq([11, 12, 11, 11])
    expect(resolved.flat_map(&:keys).uniq).not_to include('executor')
  end

  describe 'numbers' do
    it 'honours the former executor_agent_id of a model that still sends it, and the agent key assistant_<id>' do
      legacy = [{ 'fragment' => 'A', 'executor_agent_id' => 12 }, { 'fragment' => 'B', 'executor_agent_id' => '13' },
                { 'fragment' => 'C', 'executor' => 'assistant_14' }]

      resolved = described_class.new(context).resolve(legacy, mode: 'council')

      expect(resolved.pluck('executor_agent_id')).to eq([12, 13, 14])
      expect(resolved.flat_map(&:keys).uniq).to match_array(%w[fragment executor_agent_id])
    end

    it 'never takes a bare number in the executor for an agent, because the model does not see agent ids' do
      %w[answer_myself clarify].each do |mode|
        expect(resolve_ids([12, '13', '1', 'Агент 7'], mode: mode)).to eq([11, 11, 11, 11])
      end
      expect { resolve_ids(['12']) }.to raise_error(described_class::UnknownAgentError, /Unknown agent "12"/)
      expect { resolve_ids([13, 'Қабылдау']) }.to raise_error(described_class::UnknownAgentError, /Unknown agent "13"/)
    end

    it 'does not accept an id or key that is not an agent of the channel in a council' do
      expect { resolve_ids(['assistant_99']) }.to raise_error(described_class::UnknownAgentError, /Unknown agent "assistant_99"/)
      parts = [{ 'fragment' => 'A', 'executor_agent_id' => 999 }]
      expect { described_class.new(context).resolve(parts, mode: 'council') }.to raise_error(described_class::UnknownAgentError)
    end
  end

  it 'takes the current agent for an unknown name when the part is the own one' do
    %w[answer_myself clarify].each do |mode|
      expect(resolve_ids(['Неизвестный', 'Агент 7'], mode: mode)).to eq([11, 11])
    end
  end

  it 'fails with the valid names for an unknown name in a council' do
    expect { resolve_ids(%w[Қабылдау Регистратура]) }.to raise_error(
      described_class::UnknownAgentError,
      'Unknown agent "Регистратура". Use one of: Администратор, Қабылдау, Лаборатория Анализы, Приём'
    )
  end

  it 'treats two agents with the same normalized name as ambiguous for that name only' do
    graph << { id: 15, key: 'assistant_15', name: ' «КАБЫЛДАУ» ', description: 'Дубликат' }
    graph[1][:name] = 'кабылдау'

    expect(resolve_ids(['Приём', 'Администратор'])).to eq([14, 11])
    expect(resolve_ids(['Кабылдау'], mode: 'answer_myself')).to eq([11])
    expect { resolve_ids(['Приём', 'Кабылдау']) }.to raise_error(
      described_class::UnknownAgentError,
      "Unknown agent \"Кабылдау\" (several agents share this name). Use one of: Администратор, Лаборатория Анализы, Приём"
    )
  end

  describe 'on a channel with only one agent' do
    before { context[:agent_graph] = [graph.first] }

    it 'names no colleague for an unknown agent of a council' do
      expect { resolve_ids(['Любой', nil]) }.to raise_error(
        described_class::UnknownAgentError, 'Unknown agent "Любой". Use one of: Администратор'
      )
    end

    it 'sends a person to the handoff tool, not to the plan, for the former handoff mode, whatever the executor' do
      expect { described_class.new(context).reject_transfer_mode!('handoff') }.to raise_error(
        described_class::TransferToolError,
        "No other agent can be chosen on this channel. #{person_hint} For your own work use mode answer_myself."
      )
      expect(described_class::TransferToolError.ancestors).to include(described_class::RetryableError)
      expect(described_class::UnknownAgentError.ancestors).to include(described_class::RetryableError)
    end

    it 'fails a council that cannot have two agents' do
      expect { resolve_ids([nil, nil]) }.to raise_error(
        described_class::RetryableError, 'No other agent can be chosen on this channel; use mode answer_myself.'
      )
    end

    it 'keeps an own part own, whatever number is sent' do
      expect(resolve_ids(['1', nil], mode: 'answer_myself')).to eq([11, 11])
    end
  end

  describe 'a plan that contradicts its mode' do
    def fail_with(mode, executors)
      resolve_ids(executors, mode: mode)
      nil
    rescue described_class::RetryableError => e
      e
    end

    it 'sends the former handoff mode to the transfer tool of one colleague and to the handoff tool for a person' do
      expect { described_class.new(context).reject_transfer_mode!('handoff') }.to raise_error(described_class::TransferToolError) do |error|
        expect(error.reason).to eq('use_transfer_tool')
        expect(error.message).to eq(
          'plan_request has no handoff mode. To pass the conversation to one colleague, call that colleague\'s transfer tool ' \
          'without a plan. Colleagues: Қабылдау, Лаборатория Анализы, Приём. ' \
          "#{person_hint} plan_request is only for a council (separate requests for different agents) and for the answer to an open part."
        )
      end
    end

    it 'lets every other mode through the transfer check' do
      %w[answer_myself council clarify].each do |mode|
        expect(described_class.new(context).reject_transfer_mode!(mode)).to be_nil
      end
    end

    it 'asks a council of one agent for a part of a second agent' do
      [[nil, nil], %w[Қабылдау Қабылдау], ['Администратор']].each do |executors|
        expect(fail_with('council', executors).message).to eq(
          'Council needs parts for at least two different agents: name the executor of the part that is not yours. ' \
          'Use one of: Қабылдау, Лаборатория Анализы, Приём'
        )
      end
      expect(resolve_ids([nil, 'Қабылдау'], mode: 'council')).to eq([11, 12])
    end

    it 'asks an own part that names a peer to use the transfer tool of that peer or to keep the part' do
      expect(fail_with('answer_myself', ['Қабылдау']).message).to eq(
        'This part belongs to Қабылдау. Pass the conversation to that colleague with its transfer tool (no plan needed), ' \
        'or omit the executor to keep it yourself.'
      )
      expect(fail_with('answer_myself', ['assistant_13']).message).to start_with('This part belongs to Лаборатория Анализы.')
      expect(resolve_ids(['Қабылдау'], mode: 'clarify')).to eq([12])
    end

    it 'does not judge a plan that only confirms stored proposals, whatever its mode' do
      context[:parts] = [{ 'id' => 'proposal', 'state' => 'waiting_confirmation', 'executor_agent_id' => 12,
                           'proposed_operation' => { 'type' => 'create_appointment', 'params' => {} } }]
      confirm = [{ 'fragment' => 'Да', 'link_part_id' => 'proposal', 'link_action' => 'confirmation' }]

      %w[answer_myself clarify council].each do |mode|
        expect(described_class.new(context).resolve(confirm, mode: mode).sole['executor_agent_id']).to eq(12)
      end
      mixed = confirm + [{ 'fragment' => 'Ещё', 'link_action' => 'new', 'executor' => 'Қабылдау' }]
      expect { described_class.new(context).resolve(mixed, mode: 'answer_myself') }.to raise_error(described_class::RetryableError)
    end
  end

  describe 'a part linked to an open part' do
    let(:peer_part) { { 'id' => 'peer-part', 'state' => 'waiting_customer', 'executor_agent_id' => 12 } }

    before { context[:parts] = [peer_part] }

    def link_owner(attributes, mode: 'clarify')
      part = { 'fragment' => 'Ответ', 'link_part_id' => 'peer-part' }.merge(attributes)
      described_class.new(context).resolve([part], mode: mode).sole['executor_agent_id']
    end

    it 'keeps the executor of the linked part when the model names none, whatever the link action' do
      %w[answer correction cancellation].each do |action|
        expect(link_owner({ 'link_action' => action })).to eq(12)
      end
      expect(link_owner({})).to eq(12)
      expect(link_owner({ 'link_action' => 'answer', 'executor' => ' ' })).to eq(12)
    end

    it 'moves the part to the current agent only when the model names it, and starts a new part with the current agent' do
      expect(link_owner({ 'link_action' => 'answer', 'executor' => 'Администратор' }, mode: 'answer_myself')).to eq(11)
      expect(link_owner({ 'link_action' => 'new' }, mode: 'answer_myself')).to eq(11)
      expect(link_owner({ 'link_part_id' => 'gone' }, mode: 'answer_myself')).to eq(11)
    end

    it 'falls back to the current agent when the recorded executor is no longer on the channel' do
      peer_part['executor_agent_id'] = 99

      expect(link_owner({ 'link_action' => 'answer' }, mode: 'answer_myself')).to eq(11)
    end

    it 'asks an answer to a peer part, given in answer_myself without an executor, to be handed over' do
      expect { link_owner({ 'link_action' => 'answer' }, mode: 'answer_myself') }.to raise_error(
        described_class::RetryableError, /This part belongs to Қабылдау/
      )
    end
  end

  it 'keeps the executor recorded for a confirmed part when the model omits or garbles the executor, even in a council' do
    context[:parts] = [{ 'id' => 'proposal', 'state' => 'waiting_confirmation', 'executor_agent_id' => 12,
                         'proposed_operation' => { 'type' => 'create_appointment', 'params' => {} } }]
    link = { 'fragment' => 'Да', 'link_part_id' => 'proposal', 'link_action' => 'confirmation' }
    resolved = lambda do |part, mode|
      described_class.new(context).resolve([part], mode: mode).sole['executor_agent_id']
    end

    expect(resolved.call(link, 'council')).to eq(12)
    expect(resolved.call(link.merge('executor' => 'Угадай'), 'answer_myself')).to eq(12)
    expect(resolved.call(link.merge('executor' => 'Лаборатория  анализы'), 'council')).to eq(13)
    expect(resolved.call(link.merge('executor' => 'Угадай'), 'council')).to eq(12)
    expect(resolved.call(link.merge('link_action' => 'answer'), 'clarify')).to eq(12)
    expect(resolved.call(link.merge('link_part_id' => 'gone'), 'answer_myself')).to eq(11)
    expect { resolved.call(link.merge('link_action' => 'answer', 'executor' => 'Угадай'), 'council') }.to raise_error(
      described_class::UnknownAgentError
    )
  end

  it 'does not change the given parts and leaves a malformed list to the registry' do
    parts = [{ 'fragment' => 'Запрос', 'executor' => 'Қабылдау' }]

    described_class.new(context).resolve(parts, mode: 'clarify')

    expect(parts).to eq([{ 'fragment' => 'Запрос', 'executor' => 'Қабылдау' }])
    expect(described_class.new(context).resolve('not a list', mode: 'clarify')).to eq('not a list')
    expect(described_class.new(context).resolve([], mode: 'council')).to eq([])
  end

  it 'shows an agent by its name and nothing for an unknown id' do
    resolver = described_class.new(context)

    expect(resolver.name_for(13)).to eq('Лаборатория Анализы')
    expect(resolver.name_for(99)).to be_nil
  end

  it 'normalizes a name the same way for every caller' do
    expect(described_class.normalize(' «Қабылдау»  ')).to eq('қабылдау')
    expect(described_class.normalize(nil)).to eq('')
  end
end
