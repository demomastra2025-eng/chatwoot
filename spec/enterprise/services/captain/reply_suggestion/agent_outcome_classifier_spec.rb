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
