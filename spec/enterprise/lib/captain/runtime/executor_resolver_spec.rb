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
  let(:person_hint) { 'To reach a person call the handoff tool.' }
  let(:own_work_note) { 'Own work needs no plan: answer or use your tools.' }

  def resolve_ids(executors, mode: 'council')
    parts = executors.map { |executor| { 'fragment' => 'Запрос', 'executor' => executor } }
    described_class.new(context).resolve(parts, mode: mode).pluck('executor_agent_id')
  end

  it 'resolves a peer by its listed name and the own name to the current agent' do
    expect(resolve_ids(%w[Қабылдау Администратор])).to eq([12, 11])
  end

  it 'ignores case, surrounding spaces, repeated spaces and surrounding quotes' do
    variants = ['  қабылдау ', 'ҚАБЫЛДАУ', '«Қабылдау»', '"Қабылдау"', "'қабылдау'", '“Қабылдау”', ' « лаборатория   АНАЛИЗЫ » ']

    expect(resolve_ids(variants, mode: 'clarify')).to eq([12, 12, 12, 12, 12, 12, 13])
  end

  it 'matches Cyrillic names written in a decomposed unicode form' do
    expect(resolve_ids(['Приём'.unicode_normalize(:nfd), 'ПРИЁМ'], mode: 'clarify')).to eq([14, 14])
  end

  it 'takes the current agent for an omitted or blank executor, also next to a named peer' do
    parts = [{ 'fragment' => 'Свой запрос' }, { 'fragment' => 'Чужой', 'executor' => 'Қабылдау' },
             { 'fragment' => 'Пустой', 'executor' => '  ' }, { 'fragment' => 'Null', 'executor' => nil }]

    resolved = described_class.new(context).resolve(parts, mode: 'council')

    expect(resolved.pluck('executor_agent_id')).to eq([11, 12])
    expect(resolved.flat_map(&:keys).uniq).not_to include('executor')
  end

  describe 'numbers' do
    it 'honours the former executor_agent_id of a model that still sends it, and the agent key assistant_<id>' do
      legacy = [{ 'fragment' => 'A', 'executor_agent_id' => 12 }, { 'fragment' => 'B', 'executor_agent_id' => '13' },
                { 'fragment' => 'C', 'executor' => 'assistant_14' }]

      resolved = described_class.new(context).resolve(legacy, mode: 'council')

      expect(resolved.pluck('executor_agent_id')).to eq([12, 13, 14])
      expect(resolved.flat_map(&:keys).uniq).to match_array(%w[fragment executor_agent_id link_action])
    end

    it 'never takes a bare number in the executor for an agent, because the model does not see agent ids' do
      expect(resolve_ids([12, '13', '1', 'Агент 7'], mode: 'clarify')).to eq([11, 11, 11, 11])
      expect { resolve_ids(['12']) }.to raise_error(described_class::UnknownAgentError, /Unknown agent "12"/)
      expect { resolve_ids([13, 'Қабылдау']) }.to raise_error(described_class::UnknownAgentError, /Unknown agent "13"/)
    end

    it 'does not accept an id or key that is not an agent of the channel in a council' do
      expect { resolve_ids(['assistant_99']) }.to raise_error(described_class::UnknownAgentError, /Unknown agent "assistant_99"/)
      parts = [{ 'fragment' => 'A', 'executor_agent_id' => 999 }]
      expect { described_class.new(context).resolve(parts, mode: 'council') }.to raise_error(described_class::UnknownAgentError)
    end
  end

  it 'takes the current agent for an unknown name outside a council' do
    expect(resolve_ids(['Неизвестный', 'Агент 7'], mode: 'clarify')).to eq([11, 11])
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

    expect(resolve_ids(%w[Приём Администратор])).to eq([14, 11])
    expect(resolve_ids(['Кабылдау'], mode: 'clarify')).to eq([11])
    expect { resolve_ids(%w[Приём Кабылдау]) }.to raise_error(
      described_class::UnknownAgentError,
      'Unknown agent "Кабылдау" (several agents share this name). Use one of: Администратор, Лаборатория Анализы, Приём'
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
        "No other agent can be chosen on this channel. #{person_hint} #{own_work_note}"
      )
      expect(described_class::TransferToolError.ancestors).to include(described_class::RetryableError)
      expect(described_class::UnknownAgentError.ancestors).to include(described_class::RetryableError)
    end

    it 'fails a council that cannot have two agents' do
      expect { resolve_ids([nil, nil]) }.to raise_error(
        described_class::RetryableError, "No other agent can be chosen on this channel. #{own_work_note}"
      )
    end

    it 'keeps an own part own, whatever number is sent' do
      expect(resolve_ids(['1', nil], mode: 'clarify')).to eq([11, 11])
    end
  end

  describe 'a plan that contradicts its mode' do
    def fail_with(mode, executors)
      resolve_ids(executors, mode: mode)
      nil
    rescue described_class::RetryableError => e
      e
    end

    let(:add_own_action) { 'A plan holds actions for two or more different agents; an action of yours is a part without executor.' }

    it 'sends the former handoff mode to the transfer tool of one colleague and to the handoff tool for a person' do
      expect { described_class.new(context).reject_transfer_mode!('handoff') }.to raise_error(described_class::TransferToolError) do |error|
        expect(error.reason).to eq('use_transfer_tool')
        expect(error.message).to eq(
          'plan_request has no handoff mode. To pass the conversation to one colleague, call that colleague\'s transfer tool ' \
          'without a plan. Colleagues: Қабылдау, Лаборатория Анализы, Приём. ' \
          "#{person_hint} plan_request is only for a council (actions for different agents) and for the answer to an open part."
        )
      end
    end

    it 'lets every other mode through the transfer check' do
      %w[council clarify].each do |mode|
        expect(described_class.new(context).reject_transfer_mode!(mode)).to be_nil
      end
    end

    it 'tells a plan of the writer\'s own actions to do them with its tools' do
      [[nil, nil], ['Администратор']].each do |executors|
        expect(fail_with('council', executors).message).to eq("Every part of this plan is yours. #{own_work_note}")
      end
      expect(resolve_ids([nil, 'Қабылдау'], mode: 'council')).to eq([11, 12])
    end

    it 'tells a plan of one colleague to transfer the conversation with that colleague\'s transfer tool, or to add its own action' do
      expect(fail_with('council', %w[Қабылдау Қабылдау]).message).to eq(
        'If all actions of the message belong to Қабылдау, transfer the conversation to Қабылдау with transfer_to_agent_12 and plan ' \
        "nothing. #{add_own_action}"
      )
      context[:captain_v2_bound_tool_ids] = %w[faq_lookup transfer_to_agent_12 plan_request]
      expect(fail_with('council', ['Қабылдау']).message).to include('transfer the conversation to Қабылдау with transfer_to_agent_12')
    end

    it 'does not name a transfer tool that the agent does not have' do
      context[:captain_v2_bound_tool_ids] = %w[faq_lookup transfer_to_agent_13 plan_request]

      expect(fail_with('council', ['Қабылдау']).message).to eq(
        "If all actions of the message belong to Қабылдау, do them with your own tools, or call handoff for staff. #{add_own_action}"
      )
    end

    it 'links the message to the open part of that colleague when the plan names it as a new one' do
      context[:parts] = [{ 'id' => 'peer-part', 'state' => 'waiting_customer', 'executor_agent_id' => 12 }]

      message = fail_with('council', ['Қабылдау']).message

      expect(message).to start_with(
        'Қабылдау has the open part #1. If the message answers, corrects or cancels it, link it with link_part_id 1 and link_action ' \
        'answer, correction or cancellation (plan_request with mode council and ONLY that part). If all actions of the message belong to'
      )
      expect(message).to include('transfer the conversation to Қабылдау with transfer_to_agent_12')
    end

    it 'names the numbers of several open parts of that colleague, and no link when the plan declares the item new' do
      context[:parts] = [{ 'id' => 'first', 'state' => 'waiting_customer', 'executor_agent_id' => 12 },
                         { 'id' => 'second', 'state' => 'open', 'executor_agent_id' => 12 }]

      expect(fail_with('council', ['Қабылдау']).message).to start_with('Қабылдау has the open part #1, #2. ')
      expect(fail_with('council', ['Қабылдау']).message).to include('link_part_id its number and link_action')

      declared_new = [{ 'fragment' => 'Цена', 'executor' => 'Қабылдау', 'link_action' => 'new' }]
      expect { described_class.new(context).resolve(declared_new, mode: 'council') }.to raise_error(
        described_class::RetryableError, /\AIf all actions of the message belong to Қабылдау/
      )
    end

    it 'takes a peer named in a plan that is not a council as that peer\'s part, and has no own-work check' do
      expect(resolve_ids(['Қабылдау'], mode: 'clarify')).to eq([12])
      expect(resolve_ids(['assistant_13'], mode: 'clarify')).to eq([13])
      expect(described_class.private_instance_methods).not_to include(:check_own!, :check_mode!)
    end

    it 'accepts a council of one part when that part continues an open part of another agent' do
      context[:parts] = [{ 'id' => 'peer-part', 'state' => 'waiting_customer', 'executor_agent_id' => 12 }]
      answer = [{ 'fragment' => 'Давайте в 11', 'link_part_id' => 'peer-part', 'link_action' => 'answer' }]

      expect(described_class.new(context).resolve(answer, mode: 'council').sole['executor_agent_id']).to eq(12)
    end

    it 'still asks a council of one NEW part for a second agent, and accepts a continuation next to a part of the current agent' do
      context[:parts] = [{ 'id' => 'peer-part', 'state' => 'waiting_customer', 'executor_agent_id' => 12 }]
      new_part = [{ 'fragment' => 'Цена', 'link_part_id' => 'peer-part', 'link_action' => 'new' }]
      mixed = [{ 'fragment' => 'Давайте в 11', 'link_part_id' => 'peer-part', 'link_action' => 'answer' }, { 'fragment' => 'Цена' }]

      expect do
        described_class.new(context).resolve(new_part, mode: 'council')
      end.to raise_error(described_class::RetryableError, /Every part of this plan is yours/)
      expect(described_class.new(context).resolve(mixed, mode: 'council').pluck('executor_agent_id')).to eq([12, 11])
    end

    it 'names the council, not the transfer tool, when the former handoff mode is used for such a continuation' do
      context[:parts] = [{ 'id' => 'peer-part', 'state' => 'waiting_customer', 'executor_agent_id' => 12 }]
      answer = [{ 'fragment' => 'Давайте в 11', 'link_part_id' => 'peer-part', 'link_action' => 'answer' }]

      expect { described_class.new(context).reject_transfer_mode!('handoff', answer) }.to raise_error(
        described_class::TransferToolError,
        /plan_request has no handoff mode\. The patient answers, corrects or cancels a part of another agent/
      )
      expect { described_class.new(context).reject_transfer_mode!('handoff', [{ 'fragment' => 'Цена' }]) }.to raise_error(
        described_class::TransferToolError, /call that colleague's transfer tool without a plan/
      )
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

    it 'ignores an executor the model names for a continuation, and starts a new part with the current agent' do
      expect(link_owner({ 'link_action' => 'answer', 'executor' => 'Администратор' }, mode: 'council')).to eq(12)
      expect(link_owner({ 'link_action' => 'answer', 'executor' => 'Лаборатория Анализы' }, mode: 'council')).to eq(12)
      expect(link_owner({ 'link_action' => 'answer', 'executor' => 'Неизвестный' }, mode: 'council')).to eq(12)
      expect(link_owner({ 'link_action' => 'new' }, mode: 'clarify')).to eq(11)
      expect(link_owner({ 'link_part_id' => 'gone' }, mode: 'clarify')).to eq(11)
    end

    it 'falls back to the current agent when the recorded executor is no longer on the channel' do
      peer_part['executor_agent_id'] = 99

      expect(link_owner({ 'link_action' => 'answer' }, mode: 'clarify')).to eq(11)
    end
  end

  it 'keeps the executor recorded for a continued part when the model omits, garbles or changes the executor, even in a council' do
    context[:parts] = [{ 'id' => 'peer-part', 'state' => 'waiting_customer', 'executor_agent_id' => 12 }]
    link = { 'fragment' => 'Давайте в 11', 'link_part_id' => 'peer-part', 'link_action' => 'answer' }
    resolved = lambda do |part, mode|
      described_class.new(context).resolve([part], mode: mode).sole['executor_agent_id']
    end

    expect(resolved.call(link, 'council')).to eq(12)
    expect(resolved.call(link.merge('executor' => 'Угадай'), 'council')).to eq(12)
    expect(resolved.call(link.merge('executor' => 'Лаборатория  анализы'), 'council')).to eq(12)
    expect(resolved.call(link, 'clarify')).to eq(12)
    expect(resolved.call(link.merge('link_part_id' => 'gone'), 'clarify')).to eq(11)
    expect { resolved.call(link.merge('link_action' => 'new', 'executor' => 'Угадай'), 'council') }.to raise_error(
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
