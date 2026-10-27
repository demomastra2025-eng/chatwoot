require 'rails_helper'

RSpec.describe Captain::ReplySuggestion::AgentOutcomeClassifier do
  subject(:outcome) { described_class.new(payload, trace_collector: trace_collector).perform }

  let(:agent_summary) { { 'id' => 84, 'name' => 'Сезім' } }
  let(:meta) { { 'agent' => agent_summary, 'pending_actions' => [{ 'action_id' => 'a-1' }] } }
  let(:trace_collector) do
    instance_double(
      Enterprise::Captain::ReplySuggestionService::TraceCollector, suggestion_meta: meta, captain_trace: { 'version' => 1, 'tool_calls' => [] }
    )
  end
  let(:usage) { { 'prompt_tokens' => 10, 'completion_tokens' => 5, 'total_tokens' => 15 } }
  let(:reply) { { 'response' => 'Здравствуйте! Есть окно в 15:00.', 'response_mode' => 'reply', 'operator_note' => '', 'usage' => usage } }
  let(:payload) { reply }

  context 'with a reply' do
    it 'is a draft with the text, the agent, the trace and the cards' do
      expect(outcome).to include(
        outcome: 'draft', message: 'Здравствуйте! Есть окно в 15:00.', engine: 'agent', agent: agent_summary, usage: usage,
        pending_actions: [{ 'action_id' => 'a-1' }], captain_trace: { 'version' => 1, 'tool_calls' => [] }, suggestion_meta: meta
      )
    end
  end

  context 'when the agent says that no reply is needed' do
    let(:payload) do
      { 'response' => '', 'response_mode' => 'suppress', 'response_suppressed' => true, 'operator_note' => ' Пациент только  поблагодарил. ' }
    end

    it 'is no_reply with the reason for the manager' do
      expect(outcome).to include(
        outcome: 'no_reply', reason: 'Пациент только поблагодарил.', reason_source: 'agent', engine: 'agent', agent: agent_summary
      )
    end

    it 'keeps the approval cards of the run' do
      expect(outcome[:pending_actions]).to eq([{ 'action_id' => 'a-1' }])
    end

    context 'without a note' do
      let(:payload) { { 'response' => '', 'response_mode' => 'suppress', 'response_suppressed' => true, 'operator_note' => '' } }

      it 'is a failure, never a silent "no reply"' do
        expect(outcome).to include(outcome: 'failed', reason_code: 'invalid_output', detail: 'missing_operator_note')
      end
    end
  end

  context 'when the agent says that a staff member must answer' do
    let(:payload) do
      { 'response' => '', 'response_mode' => 'human', 'response_human_needed' => true, 'operator_note' => 'В базе нет данных об операциях.' }
    end

    it 'is human_needed with the reason for the manager' do
      expect(outcome).to include(outcome: 'human_needed', reason: 'В базе нет данных об операциях.', reason_source: 'agent', agent: agent_summary)
    end

    context 'without a note' do
      let(:payload) { { 'response' => '', 'response_mode' => 'human', 'operator_note' => nil } }

      it 'is a failure' do
        expect(outcome).to include(outcome: 'failed', reason_code: 'invalid_output')
      end
    end
  end

  context 'when the safety check blocked the turn' do
    let(:payload) { { 'response' => 'conversation_handoff', 'moderation_blocked' => true, 'safety_reason' => 'prompt_injection' } }

    it 'is human_needed with the reason of the platform' do
      expect(outcome).to include(
        outcome: 'human_needed', reason_source: 'safety', reason: I18n.t('captain.reply_suggestion.reasons.safety_blocked')
      )
    end
  end

  context 'when a rule of the agent stopped the turn' do
    let(:payload) do
      { 'response' => described_class::PROVIDER_ERROR, 'custom_guardrail' => { 'rule_id' => 'r1', 'reason' => 'нельзя обсуждать цены' } }
    end

    it 'is human_needed with the rule as the reason, and not a failure' do
      expect(outcome).to include(outcome: 'human_needed', reason_source: 'agent_rule')
      expect(outcome[:reason]).to include('нельзя обсуждать цены')
    end
  end

  describe 'a run that ended with an error' do
    {
      'Captain::TechnicalToolFailure' => 'tool_failure',
      'Captain::Runtime::Runner::TechnicalFailure' => 'tool_failure',
      'Captain::Runtime::Runner::ToolLoopStopped' => 'tool_loop',
      'Captain::Runtime::Runner::MaxTurnsExceeded' => 'max_turns',
      'Captain::Assistant::AgentRunnerService::BlankResponseError' => 'empty_output',
      'Captain::Assistant::AgentRunnerService::SemanticOutputError' => 'invalid_output',
      'RubyLLM::ServerError' => 'provider_error',
      'Faraday::TimeoutError' => 'provider_error',
      'Net::ReadTimeout' => 'provider_error',
      'NoMethodError' => 'agent_error'
    }.each do |error_class, code|
      it "is failed{#{code}} for #{error_class}, with no text" do
        failure = described_class.new(
          { 'response' => described_class::PROVIDER_ERROR, 'error_class' => error_class, 'error_message' => 'boom' },
          trace_collector: trace_collector
        ).perform

        expect(failure).to include(outcome: 'failed', reason_code: code, error_class: error_class)
        expect(failure).not_to have_key(:message)
      end
    end

    it 'is a provider error when the response says so without an error class' do
      failure = described_class.new({ 'response' => described_class::PROVIDER_ERROR }, trace_collector: trace_collector).perform

      expect(failure).to include(outcome: 'failed', reason_code: 'provider_error')
    end

    it 'is a failure even if the payload carries a text' do
      failure = described_class.new(reply.merge('error_class' => 'RubyLLM::Error'), trace_collector: trace_collector).perform

      expect(failure).to include(outcome: 'failed')
      expect(failure).not_to have_key(:message)
    end
  end

  context 'when the router gave the turn to the anchor only because no agent leads the dialog' do
    let(:meta) { { 'agent' => agent_summary, 'routing' => { 'decision_key' => 'route_agent_84', 'default_to' => 'anchor' } } }

    it 'says so on the outcome, so that the anchor does not become the sticky agent' do
      expect(outcome).to include(outcome: 'draft', routing_default_to: 'anchor')
      expect(Captain::ReplySuggestion::StickyAgent.agent_id_of(outcome)).to be_nil
    end
  end

  context 'when the router sent the turn to staff' do
    let(:payload) do
      { 'response' => '', 'response_mode' => 'human', 'response_human_needed' => true, 'routing_human' => true, 'agent_id' => 84,
        'operator_note' => I18n.t('captain.reply_suggestion.reasons.patient_requested_human') }
    end

    it 'is a decision of the router, with no agent named as its author' do
      expect(outcome).to include(outcome: 'human_needed', reason_source: 'router', agent: nil,
                                 reason: I18n.t('captain.reply_suggestion.reasons.patient_requested_human'))
    end
  end

  context 'when the router found that the message needs no answer' do
    let(:payload) do
      { 'response' => '', 'response_mode' => 'suppress', 'routing_no_reply' => true, 'agent_id' => 84,
        'operator_note' => I18n.t('captain.reply_suggestion.reasons.router_no_reply') }
    end

    it 'is no_reply of the router, with no agent named, no cards and no sticky agent' do
      expect(outcome).to include(outcome: 'no_reply', reason_source: 'router', agent: nil, pending_actions: [],
                                 reason: I18n.t('captain.reply_suggestion.reasons.router_no_reply'))
      expect(Captain::ReplySuggestion::StickyAgent.agent_id_of(outcome)).to be_nil
    end
  end

  # Suggestion eval 26.10: a draft offered 19:00 from the clinic text while the slot search returned 19:30 and 19:50.
  context 'when the draft names a time its scheduling reads did not find' do
    let(:payload) { reply.merge('unverified_times' => ['19:00']) }

    it 'keeps the draft and tells the manager above it which time to check' do
      expect(outcome).to include(outcome: 'draft', message: reply['response'])
      expect(outcome[:suggestion_meta]).to include(
        'unverified_times' => ['19:00'], 'operator_note' => I18n.t('captain.reply_suggestion.reasons.unverified_times', times: '19:00')
      )
    end
  end

  # Suggestion eval 27.10 (c74-1233747): the free times of one gynecologist were given under the name of the other.
  context 'when the draft gives a time under the name of a specialist whose list does not hold it' do
    let(:payload) do
      reply.merge('misattributed_times' => [{ 'name' => 'Князова Жанат', 'time' => '11:00' }, { 'name' => '', 'time' => '12:00' }],
                  'unverified_times' => ['19:00'])
    end

    it 'keeps the draft and tells the manager above it which time to check and the name it was given' do
      expected = [I18n.t('captain.reply_suggestion.reasons.unverified_times', times: '19:00'),
                  I18n.t('captain.reply_suggestion.reasons.misattributed_times', times: '11:00 (Князова Жанат)')].join(' ')

      expect(outcome).to include(outcome: 'draft', message: reply['response'])
      expect(outcome[:suggestion_meta]).to include('misattributed_times' => [{ 'name' => 'Князова Жанат', 'time' => '11:00' }],
                                                   'operator_note' => expected)
    end
  end

  # Review of the 26.10 prompts: «сколько стоит МРТ поясницы и какая подготовка?» when only staff names the preparation. The draft
  # gives the price, and the note tells the manager what to add.
  context 'when the draft leaves a part of the request to staff' do
    let(:payload) { reply.merge('operator_note' => ' Подготовку к МРТ поясницы  допишите сами. ', 'unverified_times' => ['19:00']) }

    it 'keeps the draft and shows the note of the agent above it, with the other notes' do
      expect(outcome).to include(outcome: 'draft', message: reply['response'])
      expect(outcome[:suggestion_meta]['operator_note']).to eq(
        "Подготовку к МРТ поясницы допишите сами. #{I18n.t('captain.reply_suggestion.reasons.unverified_times', times: '19:00')}"
      )
    end
  end

  describe 'a run the router could not route' do
    def failed_with(reason)
      described_class.new(
        { 'response' => described_class::PROVIDER_ERROR, 'error_class' => 'Captain::TechnicalToolFailure',
          'error_message' => "agent_router: #{reason}", 'technical_failure' => { 'tool' => 'agent_router', 'reason' => reason } },
        trace_collector: trace_collector
      ).perform
    end

    it 'is router_unavailable, not a failure of a tool' do
      %w[decision_chain_unavailable escalation_unavailable escalation_invalid].each do |reason|
        expect(failed_with(reason)).to include(outcome: 'failed', reason_code: 'router_unavailable', detail: "agent_router: #{reason}")
      end
    end

    it 'is council_unavailable when the council it chose could not be set up' do
      expect(failed_with('council_unavailable')).to include(outcome: 'failed', reason_code: 'council_unavailable')
    end

    it 'keeps tool_failure for a tool of the agent' do
      failure = described_class.new(
        { 'response' => described_class::PROVIDER_ERROR, 'error_class' => 'Captain::TechnicalToolFailure',
          'technical_failure' => { 'tool' => 'create_appointment', 'reason' => 'provider_unavailable' } },
        trace_collector: trace_collector
      ).perform

      expect(failure).to include(reason_code: 'tool_failure')
    end
  end

  describe 'a council' do
    let(:handoff) { { 'reason' => 'council_unresolved', 'parts' => ['справка для бассейна'] } }

    it 'keeps its draft and tells the manager which part needs a staff reply' do
      draft = described_class.new(reply.merge('council_turn' => true, 'council_handoff' => handoff), trace_collector: trace_collector).perform

      expect(draft).to include(outcome: 'draft', message: 'Здравствуйте! Есть окно в 15:00.')
      expect(draft[:suggestion_meta]['operator_note'])
        .to eq(I18n.t('captain.reply_suggestion.reasons.council_unresolved', parts: 'справка для бассейна'))
    end

    it 'keeps the agent it leaves the dialog with, for the sticky agent of the next suggestion' do
      draft = described_class.new(reply.merge('council_turn' => true, 'lead_agent_id' => 119), trace_collector: trace_collector).perform

      expect(draft).to include(outcome: 'draft', lead_agent_id: 119, agent: agent_summary)
      expect(Captain::ReplySuggestion::Outcome.public_result(draft)).to include('lead_agent_id' => 119)
      expect(Captain::ReplySuggestion::Outcome.public_result(described_class.new(reply, trace_collector: trace_collector).perform))
        .not_to have_key('lead_agent_id')
    end

    it 'names the parts that failed technically and the actions prepared without a text' do
      council = reply.merge('council_turn' => true,
                            'council_handoff' => { 'reason' => 'council_technical_failure', 'parts' => [], 'technical' => true,
                                                   'failed_parts' => ['перенос записи'] },
                            'council_note' => { 'unreported' => ['запись к ЛОРу'] })

      note = described_class.new(council, trace_collector: trace_collector).perform[:suggestion_meta]['operator_note']

      expect(note).to include(I18n.t('captain.reply_suggestion.reasons.council_technical', parts: 'перенос записи'),
                              I18n.t('captain.reply_suggestion.reasons.council_unreported', parts: 'запись к ЛОРу'))
    end

    context 'without a text for the patient' do
      let(:silent) { { 'response' => '', 'response_mode' => 'suppress', 'response_suppressed' => true, 'council_turn' => true } }

      it 'is no_reply with a written note and keeps its approval cards, never an invalid output' do
        result = described_class.new(silent.merge('council_note' => { 'unreported' => ['запись к ЛОРу'] }), trace_collector: trace_collector)
                                .perform

        expect(result).to include(outcome: 'no_reply', reason_source: 'agent', pending_actions: [{ 'action_id' => 'a-1' }],
                                  reason: I18n.t('captain.reply_suggestion.reasons.council_unreported', parts: 'запись к ЛОРу'))
      end

      it 'is no_reply with the general note when the council left only cards' do
        result = described_class.new(silent, trace_collector: trace_collector).perform

        expect(result).to include(outcome: 'no_reply', reason: I18n.t('captain.reply_suggestion.reasons.council_no_text'),
                                  pending_actions: [{ 'action_id' => 'a-1' }])
      end

      it 'is no_reply that says no reply is needed when no part needed one (a thanks), never a staff answer' do
        result = described_class.new(silent.merge('council_no_reply' => true), trace_collector: trace_collector).perform

        expect(result).to include(outcome: 'no_reply', reason_source: 'agent', reason: I18n.t('captain.reply_suggestion.reasons.council_no_reply'))
      end

      it 'is human_needed when a part needs a staff reply' do
        result = described_class.new(silent.merge('council_handoff' => handoff), trace_collector: trace_collector).perform

        reason = I18n.t('captain.reply_suggestion.reasons.council_unresolved', parts: 'справка для бассейна')
        expect(result).to include(outcome: 'human_needed', reason: reason)
      end
    end
  end

  # Suggestion eval 26.10 (Sezim): «Отмена завтра», a second message and an emoji; the agent answered «emoji only» and the request to
  # cancel tomorrow's visit was swallowed.
  describe 'a request that a no_reply would swallow' do
    let(:suppressed) do
      { 'response' => '', 'response_mode' => 'suppress', 'response_suppressed' => true, 'operator_note' => 'Пациент отправил только эмодзи.',
        'usage' => usage }
    end
    let(:swallowed_note) { I18n.t('captain.reply_suggestion.reasons.swallowed_request') }

    def classify(payload, text)
      described_class.new(payload, trace_collector: trace_collector, patient_text: text).perform
    end

    it 'turns the no_reply of the agent into human_needed with a note of its own, keeping the agent, the cards and the usage' do
      result = classify(suppressed, "Отмена завтра\nСегодня уже была на приёме\n🌷")

      expect(result).to include(outcome: 'human_needed', reason: swallowed_note, reason_source: 'agent', engine: 'agent', agent: agent_summary,
                                pending_actions: [{ 'action_id' => 'a-1' }], usage: usage)
      expect(swallowed_note).not_to include('эмодзи')
    end

    it 'does it for a request to move or make a visit in Russian and in Kazakh' do
      ['Можно перенести на пятницу?', 'Не смогу прийти', 'Запишите на завтра', 'Ертеңгі жазылуды болдырмаңыз', 'Келе алмаймын',
       'Уақытты ауыстырыңызшы', 'Жазылғым келеді'].each do |text|
        expect(classify(suppressed, text)).to include(outcome: 'human_needed', reason: swallowed_note), text
      end
    end

    it 'does it for the no_reply of the router, which names no agent' do
      routed = suppressed.merge('routing_no_reply' => true, 'operator_note' => 'Пациент только благодарит.')

      result = classify(routed, 'Отмена завтра')

      expect(result).to include(outcome: 'human_needed', reason: swallowed_note, reason_source: 'router', agent: nil, pending_actions: [])
    end

    it 'does it for the no_reply of a council, keeping its cards' do
      council = suppressed.merge('council_turn' => true)

      result = classify(council, 'Перенесите запись')

      expect(result).to include(outcome: 'human_needed', reason: swallowed_note, pending_actions: [{ 'action_id' => 'a-1' }])
    end

    it 'leaves a no_reply for a thanks, an emoji or a goodbye as it is, and the other outcomes of a request as they are' do
      ['Спасибо!', 'Рахмет', '👍', 'Хорошо, до свидания', '', nil].each do |text|
        expect(classify(suppressed, text)).to include(outcome: 'no_reply', reason: 'Пациент отправил только эмодзи.'), text.inspect
      end
      expect(classify(reply, 'Отмените запись')).to include(outcome: 'draft')
      human = { 'response' => '', 'response_mode' => 'human', 'operator_note' => 'Решает врач.' }
      expect(classify(human, 'Отмените запись')).to include(outcome: 'human_needed', reason: 'Решает врач.')
    end

    # Review of the cancellation guard: the patient thanks the clinic right after it confirmed a cancellation or a move.
    it 'leaves a no_reply for a thanks that names the cancellation, the move or the visit as done as it is' do
      ['Спасибо, что перенесли', 'Благодарю за перенос', 'Спасибо за отмену', 'Спасибо, что отменили запись', 'Спасибо, отменили',
       'Спасибо что передвинули', 'Спасибо, что сдвинули время', 'Рақмет, жазылдым', 'Рақмет, ауыстырғаныңызға'].each do |text|
        expect(classify(suppressed, text)).to include(outcome: 'no_reply', reason: 'Пациент отправил только эмодзи.'), text
      end
    end

    it 'still turns the no_reply of a thanks that comes with a request into human_needed' do
      ['Спасибо, перенесите на пятницу', 'Спасибо. Отмена завтра', 'Спасибо, что перенесли. Теперь отмените вторую запись',
       'Рақмет, болдырмаңыз', "Спасибо!\nЗапишите меня на субботу"].each do |text|
        expect(classify(suppressed, text)).to include(outcome: 'human_needed', reason: swallowed_note), text
      end
    end

    it 'does not look at a patient text that was not given' do
      expect(described_class.new(suppressed, trace_collector: trace_collector).perform).to include(outcome: 'no_reply')
    end
  end

  # Review of quality-fixes-1 (M1): the router and the agent both decide a silence; the check of the words and the facts is made on their
  # outcome (Captain::SilenceCheck). A yes to a time staff offered and a confirmation of a visit nobody agreed are not swallowed; a
  # plain thanks, ok or «буду» is silent also after a voice note of staff (the eval of 27.10: 6 of the 10 wrong handoffs).
  describe 'a silence about an offer or a visit nobody agreed' do
    let(:suppressed) do
      { 'response' => '', 'response_mode' => 'suppress', 'response_suppressed' => true, 'operator_note' => 'Пациент только благодарит.',
        'usage' => usage }
    end
    let(:note) { I18n.t('captain.reply_suggestion.reasons.unsafe_silence') }
    let(:none) { Captain::Runtime::AgreedVisit::NONE }
    let(:booked) { Captain::Runtime::AgreedVisit.new(times: ['10:00']) }

    def classify(payload, text, last_clinic:, visit:)
      described_class.new(payload, trace_collector: trace_collector, patient_text: text, last_clinic: last_clinic, visit: visit).perform
    end

    it 'turns the no_reply of the agent into human_needed for a yes to a time that staff offered, keeping the agent and the cards' do
      result = classify(suppressed, 'Да, подходит', last_clinic: 'Есть окно завтра в 14:00.', visit: booked)

      expect(result).to include(outcome: 'human_needed', reason: note, reason_source: 'agent', engine: 'agent', agent: agent_summary,
                                pending_actions: [{ 'action_id' => 'a-1' }], usage: usage)
    end

    it 'does it for the no_reply of the router, which names no agent, and for the one of a council' do
      routed = suppressed.merge('routing_no_reply' => true)

      expect(classify(routed, 'Ок', last_clinic: 'Есть окно завтра в 14:00.', visit: none))
        .to include(outcome: 'human_needed', reason: note, reason_source: 'router', agent: nil, pending_actions: [])
      expect(classify(suppressed.merge('council_turn' => true), 'Спасибо, буду', last_clinic: 'Ждём вас завтра', visit: none))
        .to include(outcome: 'human_needed', reason: note, pending_actions: [{ 'action_id' => 'a-1' }])
    end

    it 'does it for a confirmation when nothing is booked' do
      expect(classify(suppressed, 'Спасибо, буду', last_clinic: 'Ваша стоимость 8000 тенге.', visit: none))
        .to include(outcome: 'human_needed', reason: note)
    end

    # The eval of 27.10 (c78-1214235, c78-1244961, c76-1205215): a thanks after a voice note of staff was sent to staff.
    it 'keeps the no_reply of a bare thanks, ok or confirmation after a voice note of staff without a transcript' do
      voice = "[Mon 26.10 18:59] #{Captain::ReplySuggestion::HistoryBuilder::STAFF_VOICE_NOTE}"

      ['Спасибо', 'Ок', 'Ок, спасибо', 'Рахмет, келемін', 'Спасибо, буду'].each do |text|
        expect(classify(suppressed, text, last_clinic: voice, visit: booked)).to include(outcome: 'no_reply'), text
      end
    end

    # The history writes the send time in front of every message: it is no time that the clinic offered.
    it 'does not take the send time of the last message of the clinic for a time it offered' do
      reminder = '[Sat 24.10 09:50] Напоминаем: завтра в 10:00 у вас приём.'

      ['Ок', 'Спасибо, буду', 'Хорошо, придём'].each do |text|
        expect(classify(suppressed, text, last_clinic: reminder, visit: booked)).to include(outcome: 'no_reply'), text
      end
      expect(classify(suppressed, 'Да, подходит', last_clinic: '[Sat 24.10 09:50] Есть окно завтра в 14:00.', visit: booked))
        .to include(outcome: 'human_needed', reason: note)
    end

    it 'keeps the no_reply of a confirmation of the visit the contact has, of a plain thanks and of a reminder acknowledged' do
      reminder = 'Напоминаем: завтра в 10:00 у вас приём.'

      [['Спасибо, буду', reminder], ['Ок', reminder], ['Хорошо, придём', reminder], ['Спасибо!', 'Есть окно завтра в 14:00.'],
       ['Спасибо', 'УЗИ почек стоит 8000 тенге.']].each do |text, last_clinic|
        expect(classify(suppressed, text, last_clinic: last_clinic, visit: booked)).to include(outcome: 'no_reply'), text
      end
    end

    it 'does not make the check without the facts of the dialog, and leaves the other outcomes as they are' do
      expect(described_class.new(suppressed, trace_collector: trace_collector, patient_text: 'Да, подходит').perform).to include(outcome: 'no_reply')
      expect(classify(reply, 'Да, подходит', last_clinic: 'Есть окно завтра в 14:00.', visit: none)).to include(outcome: 'draft')
    end

    it 'keeps the note of a request to cancel when both apply' do
      result = classify(suppressed, 'Спасибо, не буду', last_clinic: 'Напоминаем: завтра в 10:00 у вас приём.', visit: booked)

      expect(result).to include(outcome: 'human_needed', reason: I18n.t('captain.reply_suggestion.reasons.swallowed_request'))
    end
  end

  describe 'a reply that cannot be given' do
    it 'fails a handoff: a suggestion has no such thing' do
      failure = described_class.new({ 'response' => 'conversation_handoff' }, trace_collector: trace_collector).perform

      expect(failure).to include(outcome: 'failed', reason_code: 'invalid_output')
    end

    it 'fails a cancelled response' do
      failure = described_class.new({ 'response' => 'response_cancelled', 'response_cancelled' => true }, trace_collector: trace_collector).perform

      expect(failure).to include(outcome: 'failed', reason_code: 'invalid_output')
    end

    it 'fails an empty reply' do
      failure = described_class.new({ 'response' => '   ', 'response_mode' => 'reply' }, trace_collector: trace_collector).perform

      expect(failure).to include(outcome: 'failed', reason_code: 'empty_output')
    end
  end
end
