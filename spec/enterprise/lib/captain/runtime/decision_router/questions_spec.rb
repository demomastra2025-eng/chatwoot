# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Runtime::DecisionRouter::Questions do
  # A dialog in which the clinic asked the patient nothing.
  def dialog = [{ role: 'clinic', agent_id: 20, text: 'Вы записаны на четверг.' }]

  def snapshot(count, current: nil, human: true, card: 'Услуги агента', suggestion: false, anchor: nil, # rubocop:disable Metrics/ParameterLists
               history: dialog, message: 'Спасибо!')
    agents = (1..count).map { |id| Captain::Runtime::RoutingSnapshot::Agent.new(id: id * 10, label: "Agent #{id}", card: card) }
    Captain::Runtime::RoutingSnapshot.new(agents: agents, latest_message: message, current_agent_id: current, human_available: human,
                                          suggestion: suggestion, anchor_agent_id: anchor, recent_messages: history)
  end

  def build(count, mode: :full, **)
    described_class.build(snapshot(count, **), instructions: 'ROUTER RULES', mode: mode)
  end

  it 'asks route_mode and one yes/no question per agent in one call, with the card of the agent in its yes criterion' do
    questions = build(3, current: 20, card: 'УЗИ всех видов').to_h

    expect(questions.keys).to eq(%w[route_mode include_agent_10 include_agent_20 include_agent_30])
    expect(questions['route_mode']).to include(instructions: 'ROUTER RULES')
    expect(questions['route_mode'][:criteria].keys).to eq(%w[stay_current route_agent council human_handoff no_reply_needed])
    expect(questions['include_agent_10'][:criteria].keys).to eq(%w[yes no])
    expect(questions['include_agent_10'][:criteria]['yes']).to include('Agent 10 (Agent 1)', 'УЗИ всех видов')
    expect(questions['include_agent_10'][:instructions]).to include('just in case', 'several services of one agent make only that agent yes')
  end

  it 'offers no stay_current on the first message and human_handoff only when staff can take the conversation' do
    expect(build(3).mode_keys).to eq(%w[route_agent council human_handoff no_reply_needed])
    expect(build(3, current: 10, human: false).mode_keys).to eq(%w[stay_current route_agent council no_reply_needed])
  end

  # Router benchmark 26.10 (AS06, IS06, SS05): a plain thanks with no sticky agent became a council, because the cards of v2 have no
  # catch-all agent of general questions. A message that needs no answer has an answer of its own.
  it 'offers no_reply_needed for a message that needs no answer, with or without a current agent' do
    description = build(3).to_h['route_mode'][:criteria]['no_reply_needed']

    expect(description).to include('only thanks, says ok or goodbye, or sends an emoji', 'never a council',
                                   'accepts or declines no offered time or booking', 'A greeting opens or resumes the dialog: not this',
                                   'a thumbs-up that answers a clinic question offering a time or a booking accepts it: not this')
    expect(description).not_to include('greets')
    expect(build(3, current: 10).mode_keys).to include('no_reply_needed')
  end

  it 'offers a council part that was not its owner\'s one agent, staff or nobody, never a council or a stay' do
    expect(build(3, current: 10, mode: :singles).mode_keys).to eq(%w[route_agent human_handoff nobody])
  end

  it 'keeps every criterion within the limit of the endpoint and stays within its question limit' do
    questions = build(3, card: 'Я' * 3000).to_h

    expect(questions.values.flat_map { |question| question[:criteria].values }.map(&:length).max).to be <= described_class::MAX_DESCRIPTION
    expect(questions.keys).to all(match(Llm::OpenRouterDecisionClient::QUESTION_NAME))
    expect { build(described_class::MAX_AGENTS + 1) }.to raise_error(ArgumentError, /at most/)
  end

  describe '#resolve' do
    let(:questions) { build(3, current: 20) }

    # Answers as the endpoint gives them: a chosen key with its confidence and, when given, the probabilities of the keys.
    def answer(choice, confidence: 0.9, probabilities: {})
      Llm::OpenRouterDecisionClient::Answer.new(choice: choice, confidence: confidence, probabilities: probabilities)
    end

    def answered(mode, yes: [], all: [10, 20, 30], mode_probabilities: {}, include_probabilities: {})
      { 'route_mode' => answer(mode, probabilities: mode_probabilities) }.merge(all.to_h do |id|
        probability = include_probabilities[id]
        probabilities = probability ? { 'yes' => probability, 'no' => (1 - probability).round(4) } : {}
        ["include_agent_#{id}", answer(yes.include?(id) ? 'yes' : 'no', probabilities: probabilities)]
      end)
    end

    it 'routes to the one agent that is yes' do
      expect(questions.resolve(answered('route_agent', yes: [30]))).to have_attributes(kind: 'agent', agent_ids: [30], key: 'route_agent_30')
    end

    it 'takes the route_mode key with the highest probability, the chosen one on a tie or without probabilities' do
      staff = build(3, current: 20, message: 'Соедините с оператором')
      expect(staff.resolve(answered('route_agent', yes: [30], mode_probabilities: { 'route_agent' => 0.3, 'human_handoff' => 0.7 })))
        .to have_attributes(kind: 'human', key: 'human_handoff', confidence: 0.7)
      expect(questions.resolve(answered('route_agent', yes: [30], mode_probabilities: { 'route_agent' => 0.5, 'human_handoff' => 0.5 })))
        .to have_attributes(key: 'route_agent_30', confidence: 0.5)
      expect(questions.resolve(answered('route_agent', yes: [30]))).to have_attributes(key: 'route_agent_30', confidence: 0.9)
    end

    it 'routes to the agent with the highest include probability, never the current agent; to it only when no other is left' do
      expect(questions.resolve(answered('route_agent', yes: [20], include_probabilities: { 10 => 0.3, 20 => 0.9, 30 => 0.4 })).key)
        .to eq('route_agent_30')
      expect(questions.resolve(answered('route_agent')).key).to eq('route_agent_10')
      expect(questions.resolve(answered('route_agent', yes: [10, 30], include_probabilities: { 10 => 0.6, 30 => 0.8 })).key)
        .to eq('route_agent_30')
      expect(build(1, current: 10).resolve(answered('route_agent', all: [10]))).to have_attributes(kind: 'stay', key: 'stay_current')
    end

    it 'keeps the current agent on stay_current whatever the include answers say, and routes to the top agent without one' do
      expect(questions.resolve(answered('stay_current', yes: [10]))).to have_attributes(kind: 'stay', agent_ids: [20], key: 'stay_current')
      expect(build(3).resolve(answered('stay_current', include_probabilities: { 10 => 0.2, 20 => 0.1, 30 => 0.45 })))
        .to have_attributes(kind: 'agent', key: 'route_agent_30')
    end

    it 'holds a council of the agents at 0.5 or more, ids ascending, the three most probable at most' do
      expect(questions.resolve(answered('council', yes: [30, 10]))).to have_attributes(kind: 'council', agent_ids: [10, 30], key: 'council_10_30')
      expect(questions.resolve(answered('council', yes: [10, 20, 30])).key).to eq('council_10_20_30')
      four = build(4).resolve(answered('council', all: [10, 20, 30, 40],
                                                  include_probabilities: { 10 => 0.55, 20 => 0.9, 30 => 0.5, 40 => 0.8 }))
      expect(four.key).to eq('council_10_20_40')
    end

    it 'routes a council of fewer than two agents to the most probable agent, a stay when that is the current one' do
      expect(questions.resolve(answered('council', yes: [30]))).to have_attributes(kind: 'agent', key: 'route_agent_30')
      expect(questions.resolve(answered('council', yes: [20]))).to have_attributes(kind: 'stay', key: 'stay_current')
      expect(build(3).resolve(answered('council', include_probabilities: { 10 => 0.1, 20 => 0.3, 30 => 0.2 })).key).to eq('route_agent_20')
    end

    it 'never takes several services of one agent for a council' do
      expect(build(3).resolve(answered('council', yes: [20])).key).to eq('route_agent_20')
    end

    it 'gives staff whatever the include answers say, for a message that asks for a person' do
      staff = build(3, current: 20, message: 'Дайте мне живого администратора, не хочу переписываться с ботом')

      expect(staff.resolve(answered('human_handoff', yes: [10]))).to have_attributes(kind: 'human', agent_ids: [], key: 'human_handoff')
    end

    it 'gives staff for a call-back, a complaint, a refund or a legal matter, in Russian and in Kazakh' do
      ['Перезвоните мне, пожалуйста', 'Это жалоба на врача', 'Верните деньги за приём', 'Подам в суд', 'Оператормен байланыстырыңыз',
       'Тірі адаммен сөйлескім келеді', 'Шағым айтқым келеді', 'ақшамды қайтарыңыз'].each do |text|
        resolved = build(3, current: 20, message: text).resolve(answered('human_handoff', yes: [10]))

        expect(resolved).to have_attributes(kind: 'human', key: 'human_handoff'), text
      end
    end

    # Suggestion eval 26.10 (Sezim): the decision model answered human_handoff (0.71) for the first message of a dialog, a question
    # about free times for a child; the dialog never reached an agent. The words did not ask for a person, so an agent answers.
    describe 'a human_handoff of the model for a message that asks for no person' do
      let(:plain) { 'Есть окно сегодня или завтра для ребёнка к ЛОРу?' }
      let(:probabilities) { { 10 => 0.2, 20 => 0.7, 30 => 0.4 } }

      it 'goes to the agent with the highest include probability' do
        expect(build(3, message: plain).resolve(answered('human_handoff', include_probabilities: probabilities)))
          .to have_attributes(kind: 'agent', agent_ids: [20], key: 'route_agent_20', confidence: 0.9)
        expect(build(3, current: 30, message: plain).resolve(answered('human_handoff', include_probabilities: probabilities)).key)
          .to eq('route_agent_20')
      end

      it 'is a stay when the current agent is the most probable one' do
        resolved = build(3, current: 30, message: plain)
                   .resolve(answered('human_handoff', include_probabilities: { 10 => 0.1, 20 => 0.1, 30 => 0.9 }))

        expect(resolved).to have_attributes(kind: 'stay', agent_ids: [30], key: 'stay_current')
      end

      it 'prefers the current agent, then the anchor of the channel, then the lower id, when the include answers are all alike' do
        expect(build(3, current: 20, message: plain).resolve(answered('human_handoff')).key).to eq('stay_current')
        expect(build(3, suggestion: true, anchor: 30, message: plain).resolve(answered('human_handoff')).key).to eq('route_agent_30')
        expect(build(3, message: plain).resolve(answered('human_handoff')).key).to eq('route_agent_10')
      end

      it 'is not checked for a council part, which keeps the word of the model' do
        part = build(3, current: 10, mode: :singles, message: plain)

        expect(part.resolve(answered('human_handoff', all: [20, 30]))).to have_attributes(kind: 'human', key: 'human_handoff')
      end
    end

    it 'needs no answer for a bare thanks and keeps the current agent of the dialog when there is one' do
      expect(questions.resolve(answered('no_reply_needed', yes: [20])))
        .to have_attributes(kind: 'no_reply', agent_ids: [20], key: 'no_reply_needed', confidence: 0.9)
      expect(build(3).resolve(answered('no_reply_needed'))).to have_attributes(kind: 'no_reply', agent_ids: [])
      expect(build(3, message: 'Рахмет, сау болыңыз 🙏').resolve(answered('no_reply_needed')).kind).to eq('no_reply')
    end

    # Review of df3aaff78: no_reply_needed silences the turn, so an answer that contradicts it never ends as no_reply.
    it 'routes a no_reply_needed with an include answer yes for another agent to the most probable such agent' do
      asks = build(3, current: 20, message: 'Спасибо! А УЗИ почек сколько стоит?')

      expect(questions.resolve(answered('no_reply_needed', yes: [10, 30], include_probabilities: { 10 => 0.6, 30 => 0.8 })))
        .to have_attributes(kind: 'agent', key: 'route_agent_30')
      expect(asks.resolve(answered('no_reply_needed', yes: [10]))).to have_attributes(kind: 'agent', key: 'route_agent_10')
      expect(build(3).resolve(answered('no_reply_needed', yes: [20]))).to have_attributes(kind: 'agent', key: 'route_agent_20')
    end

    it 'keeps a no_reply_needed that asks or names something, or answers a clinic question, with the current agent' do
      offer = [{ role: 'clinic', agent_id: 20, text: 'В четверг свободно 14:00. Записать вас на 14:00?' }]

      ['Спасибо! А УЗИ почек сколько стоит?', 'Хорошо, тогда в 14:00', 'Спасибо, но я ещё подумаю и напишу вам позже'].each do |text|
        expect(build(3, current: 20, message: text).resolve(answered('no_reply_needed'))).to have_attributes(kind: 'stay', key: 'stay_current')
      end
      %w[Ок 👍 Жарайды].each do |text|
        expect(build(3, current: 20, message: text, history: offer).resolve(answered('no_reply_needed')).key).to eq('stay_current')
      end
      expect(build(3, message: 'Ок', history: offer).resolve(answered('no_reply_needed', include_probabilities: { 10 => 0.1, 20 => 0.4 })))
        .to have_attributes(kind: 'agent', key: 'route_agent_20')
    end

    # Review of df3aaff78 (router benchmark SZ20): a first «Здравствуйте!» waits for an answer.
    it 'answers a message that opens the dialog, also when the decision models found it needs no answer' do
      opening = build(3, message: 'Здравствуйте!', history: [])

      expect(opening.resolve(answered('no_reply_needed', include_probabilities: { 10 => 0.3, 20 => 0.1, 30 => 0.2 })))
        .to have_attributes(kind: 'agent', key: 'route_agent_10')
    end

    it 'has no default of a reply suggestion: the anchor answers only when it is the most probable agent' do
      suggestion = build(3, suggestion: true, anchor: 30)

      expect(suggestion.resolve(answered('route_agent', include_probabilities: { 10 => 0.4, 20 => 0.1, 30 => 0.2 })).key).to eq('route_agent_10')
    end

    it 'counts the chosen answer of a model that gave no probabilities as the more probable one, by its confidence' do
      unsure = { 'route_mode' => answer('council'), 'include_agent_10' => answer('yes', confidence: 0.3),
                 'include_agent_20' => answer('no', confidence: 0.75), 'include_agent_30' => answer('yes', confidence: nil) }

      expect(build(3).include_probabilities(unsure)).to eq(10 => 0.65, 20 => 0.125, 30 => 1.0)
      expect(build(3).resolve(unsure).key).to eq('council_10_30')
      expect(build(3).include_probabilities('include_agent_10' => answer('no', confidence: nil))).to eq(10 => 0.0, 20 => 0.0, 30 => 0.0)
    end

    it 'routes a council part to the agent that is yes, also the current one, or to nobody' do
      part = build(3, current: 10, mode: :singles)

      expect(part.resolve(answered('route_agent', yes: [10]))).to have_attributes(kind: 'agent', key: 'route_agent_10')
      expect(part.resolve(answered('nobody'))).to have_attributes(kind: 'none', key: 'nobody')
      expect(part.resolve(answered('no_reply_needed'))).to be_nil
    end
  end

  it 'summarizes the chosen keys for the logs' do
    expect(described_class.summary('route_mode' => 'council', 'include_agent_10' => 'yes')).to eq('route_mode=council include_agent_10=yes')
  end
end
