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
