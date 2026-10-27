# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Runtime::DecisionRouter::Questions do
  # A dialog in which the clinic asked the patient nothing, and the visit it states is the one the contact has.
  def dialog = [{ role: 'clinic', agent_id: 20, text: 'Вы записаны на четверг.' }]

  def booked = Captain::Runtime::AgreedVisit.new(times: ['10:00'])

  def snapshot(count, current: nil, human: true, card: 'Услуги агента', suggestion: false, anchor: nil, # rubocop:disable Metrics/ParameterLists
               history: dialog, message: 'Спасибо!', visit: booked)
    agents = (1..count).map { |id| Captain::Runtime::RoutingSnapshot::Agent.new(id: id * 10, label: "Agent #{id}", card: card) }
    Captain::Runtime::RoutingSnapshot.new(agents: agents, latest_message: message, current_agent_id: current, human_available: human,
                                          suggestion: suggestion, anchor_agent_id: anchor, recent_messages: history, visit: visit)
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

  # Suggestion eval 27.10 (c76-1205215, c78-1186457, c77-1198258): after a time was agreed (a voice note of the operator had no text)
  # the patient wrote «Ок Рахмет / Принял / Буду» and the agent started the booking again. The platform sends no such confirmation to
  # staff, also after a voice note: nothing in the questions mentions one.
  it 'describes a bare confirmation of an agreed visit as no_reply_needed, with no exception for a clinic voice note' do
    description = build(3).to_h['route_mode'][:criteria]['no_reply_needed']

    expect(description).to include('A thanks, ok or "буду", "придём", "келемін" that only confirms a visit or a time the clinic already ' \
                                   'agreed, booked or confirmed closes the topic: this. A greeting opens or resumes the dialog: not this',
                                   'a thumbs-up that answers a clinic question offering a time or a booking accepts it: not this')
    expect(description).not_to match(/voice/i)
    expect(description.length).to be <= described_class::MAX_DESCRIPTION
  end

  # Router benchmark A23 (26.10, review of the human_handoff gate): «Перестаньте мне писать» was no_reply_needed, which no keyword gate sees.
  # The gate takes the include answers of a human_handoff as they come, so the models are asked for no agent in it.
  it 'describes human_handoff with every include answer no and a demand to stop writing, and keeps that demand out of no_reply_needed' do
    criteria = build(3, current: 10).to_h['route_mode'][:criteria]

    expect(criteria['human_handoff']).to include('refuses to continue with the assistant (asks it to stop writing)',
                                                 'Every include_agent question is no.')
    expect(criteria['no_reply_needed']).to include('A demand to stop writing is not this either.')
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

    # The review of the human_handoff gate (26.10) kept staff for a human_handoff that no agent fits (every include probability below
    # 0.5). Suggestion eval 27.10 (c78-1250261): a human_handoff is asked with every include answer no, so those probabilities say
    # nothing about whether an agent fits, and a plain question about a children's ENT, the first message of a dialog, went to staff in
    # both runs. Staff take the turn for the words of a person, a complaint, a refund or a legal matter, and for no agent to ask.
    describe 'a human_handoff of the model for a message that asks for no person, whatever the include probabilities' do
      let(:plain) { 'Есть окно сегодня или завтра для ребёнка к ЛОРу?' }
      let(:unknown) { 'Мне нужен кто-то, кто решит мой вопрос' }
      let(:below_half) { { 10 => 0.1, 20 => 0.45, 30 => 0.3 } }

      it 'goes to the agent with the highest include probability, also when every include probability is below 0.5' do
        expect(Captain::PatientIntent.human_request?(plain)).to be(false)
        expect(Captain::PatientIntent.human_request?(unknown)).to be(false)

        [plain, unknown].each do |text|
          expect(build(3, message: text).resolve(answered('human_handoff', include_probabilities: below_half)))
            .to have_attributes(kind: 'agent', agent_ids: [20], key: 'route_agent_20', confidence: 0.9)
          expect(build(3, current: 30, message: text).resolve(answered('human_handoff', include_probabilities: below_half)).key)
            .to eq('route_agent_20')
          expect(build(3, current: 20, message: text).resolve(answered('human_handoff', include_probabilities: below_half)))
            .to have_attributes(kind: 'stay', agent_ids: [20], key: 'stay_current')
        end
      end

      it 'prefers the current agent, then the anchor of the channel, then the lower id, when the agents are all alike or none fits' do
        alike = answered('human_handoff', yes: [10, 20, 30])
        none = answered('human_handoff')

        expect(build(3, current: 20, message: plain).resolve(alike).key).to eq('stay_current')
        expect(build(3, suggestion: true, anchor: 30, message: plain).resolve(alike).key).to eq('route_agent_30')
        expect(build(3, message: plain).resolve(alike).key).to eq('route_agent_10')
        expect(build(3, message: plain).resolve(none).key).to eq('route_agent_10')
        expect(build(3, suggestion: true, anchor: 30, message: plain).resolve(none).key).to eq('route_agent_30')
        expect(build(3, current: 20, message: plain).resolve(none).key).to eq('stay_current')
      end

      it 'takes a model that gave no probabilities by its yes' do
        expect(build(3, message: plain).resolve(answered('human_handoff', yes: [30]))).to have_attributes(kind: 'agent', key: 'route_agent_30')
      end

      it 'is not checked for a council part, which keeps the word of the model' do
        part = build(3, current: 10, mode: :singles, message: plain)

        expect(part.resolve(answered('human_handoff', all: [20, 30]))).to have_attributes(kind: 'human', key: 'human_handoff')
        expect(part.resolve(answered('human_handoff', yes: [20, 30], all: [20, 30]))).to have_attributes(kind: 'human', key: 'human_handoff')
      end

      it 'gives staff for the wordings of a person, a call, the front desk and the administrator, a complaint, a refund and a legal matter' do
        ['Можете позвонить?', 'Можете мне позвонить?', 'Можете перезвонить?', 'Позвони мне', 'Свяжите с регистратурой', 'Отдайте мои деньги',
         'Я недоволен вашим сервисом', 'Перестаньте мне писать', 'operator', 'administrator', 'please call me', 'I want to talk to a manager',
         'Админге қосыңыз', 'Хочу пожаловаться'].each do |text|
          resolved = build(3, current: 20, message: text).resolve(answered('human_handoff', yes: [10, 20, 30]))

          expect(resolved).to have_attributes(kind: 'human', key: 'human_handoff'), text
        end
      end

      it 'gives staff when there is no agent to ask' do
        expect(build(0, message: unknown).resolve(answered('human_handoff', all: []))).to have_attributes(kind: 'human', key: 'human_handoff')
      end
    end

    it 'needs no answer for a bare thanks and keeps the current agent of the dialog when there is one' do
      expect(questions.resolve(answered('no_reply_needed', yes: [20])))
        .to have_attributes(kind: 'no_reply', agent_ids: [20], key: 'no_reply_needed', confidence: 0.9)
      expect(build(3).resolve(answered('no_reply_needed'))).to have_attributes(kind: 'no_reply', agent_ids: [])
      expect(build(3, message: 'Рахмет, сау болыңыз 🙏').resolve(answered('no_reply_needed')).kind).to eq('no_reply')
    end

    # Suggestion eval 27.10 (c78-1214235, c78-1244961): the operator's voice note had no text, so the last clinic message asks nothing, and a
    # bare thanks, ok or «буду» after it needs no answer, as after any other message. A question, or a refusal to come, is still answered.
    it 'takes a no_reply_needed for a bare thanks, ok or confirmation after a clinic voice note whose words are unknown' do
      voice = [{ role: 'clinic', agent_id: 20, text: "[Mon 26.10 18:59] #{Captain::ReplySuggestion::HistoryBuilder::STAFF_VOICE_NOTE}" }]

      ['Ок Рахмет Принял Буду', 'Спасибо, буду', 'Рахмет, келемін', 'Спасибо', 'Ок, спасибо'].each do |text|
        expect(build(3, current: 20, message: text, history: voice).resolve(answered('no_reply_needed')))
          .to have_attributes(kind: 'no_reply', key: 'no_reply_needed'), text
      end
      ['А во сколько?', 'Спасибо, не буду'].each do |text|
        expect(build(3, current: 20, message: text, history: voice).resolve(answered('no_reply_needed')))
          .to have_attributes(kind: 'stay', key: 'stay_current'), text
      end
      expect(build(3, message: 'Спасибо, буду', history: voice).resolve(answered('no_reply_needed', include_probabilities: { 10 => 0.1, 20 => 0.4 })))
        .to have_attributes(kind: 'no_reply')
    end

    # The history writes the send time in front of every message ("[Wed 28.10 12:53] Спасибо"): its digits are no word of the patient, and
    # its clock is no time that the clinic offered.
    it 'reads the words of the messages, not the send time the history writes in front of them' do
      reminder = [{ role: 'clinic', agent_id: 20, text: '[Wed 28.10 12:01] Напоминаем: завтра в 10:00 у вас приём. Ждём вас.' }]

      ['Ок', 'Спасибо, буду', 'Хорошо, придём', "Спасибо\nБуду"].each do |text|
        expect(build(3, current: 20, message: text, history: reminder).resolve(answered('no_reply_needed')).kind).to eq('no_reply'), text
      end
    end

    # Review of quality-fixes-1 (H2): «спасибо, буду» is a courtesy, «спасибо, не буду» is a cancellation. The words of the cancellation
    # are checked in the router, as they are in the classifier.
    it 'keeps a refusal to come, and any other cancellation behind a thanks, with the current agent' do
      ['Спасибо, не буду', 'Не получится', 'Рахмет, келмеймін', 'Спасибо, не пойду', 'Не могу прийти', 'Спасибо. Отмена'].each do |text|
        expect(build(3, current: 20, message: text).resolve(answered('no_reply_needed'))).to have_attributes(kind: 'stay', key: 'stay_current'), text
      end
    end

    # Review of quality-fixes-1 (L6): a question without a question mark is no bare thanks.
    it 'keeps a question put in words, with no question mark, with the current agent' do
      ['Спасибо, буду. Адрес какой', 'Рахмет, қашан келемін', 'Спасибо, можно позже', 'Ок где вы находитесь'].each do |text|
        expect(build(3, current: 20, message: text).resolve(answered('no_reply_needed'))).to have_attributes(kind: 'stay', key: 'stay_current'), text
      end
    end

    # Review of quality-fixes-1 (M1): staff offered a time without a question mark; a yes accepts it, and nothing is booked by a silence.
    describe 'a short answer to a time that the clinic offered' do
      let(:offer) { [{ role: 'clinic', agent_id: 20, text: 'Есть окно завтра в 14:00.' }] }
      let(:reminder) { [{ role: 'clinic', agent_id: 20, text: 'Напоминаем: завтра в 10:00 у вас приём. Ждём вас.' }] }
      let(:no_visit) { Captain::Runtime::AgreedVisit::NONE }

      it 'is an acceptance, so the current agent answers it, whether or not the contact has another visit' do
        ['Да, подходит', 'Ок', 'Хорошо', 'Жарайды', 'Давайте'].each do |text|
          [booked, no_visit].each do |visit|
            expect(build(3, current: 20, message: text, history: offer, visit: visit).resolve(answered('no_reply_needed')))
              .to have_attributes(kind: 'stay', key: 'stay_current'), text
          end
        end
      end

      it 'is a courtesy after the reminder of a visit the contact has, and not after the same words when nothing is agreed' do
        ['Ок', 'Хорошо', 'Спасибо, буду', 'Хорошо, придём', 'Рахмет, келемін'].each do |text|
          expect(build(3, current: 20, message: text, history: reminder).resolve(answered('no_reply_needed')))
            .to have_attributes(kind: 'no_reply', key: 'no_reply_needed'), text
          expect(build(3, current: 20, message: text, history: reminder, visit: no_visit).resolve(answered('no_reply_needed')).kind)
            .to eq('stay'), text
        end
      end

      it 'is a courtesy, with a booking card that waits for approval, after the time the card was prepared for' do
        pending_card = Captain::Runtime::AgreedVisit.new(pending: true)

        expect(build(3, current: 20, message: 'Спасибо, буду', history: offer, visit: pending_card).resolve(answered('no_reply_needed')).kind)
          .to eq('no_reply')
      end

      it 'does not stop a plain thanks, which accepts nothing' do
        thanks = build(3, current: 20, message: 'Спасибо!', history: offer, visit: no_visit)

        expect(thanks.resolve(answered('no_reply_needed')).kind).to eq('no_reply')
      end
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
