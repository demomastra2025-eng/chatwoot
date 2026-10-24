require 'rails_helper'

RSpec.describe Captain::ReplySuggestion::Outcome do
  describe '.normalize' do
    it 'keeps an outcome as it is' do
      outcome = { outcome: 'draft', message: 'Здравствуйте', engine: 'agent' }

      expect(described_class.normalize(outcome)).to eq(outcome)
    end

    it 'maps the errors of the task wrapper to a failure' do
      expect(described_class.normalize({ error: 'limit', error_code: 429 })).to include(outcome: 'failed', reason_code: 'quota_exceeded')
      expect(described_class.normalize({ error: 'key', error_code: 401 })).to include(outcome: 'failed', reason_code: 'api_key_missing')
      expect(described_class.normalize({ error: 'off' })).to include(outcome: 'failed', reason_code: 'disabled')
      expect(described_class.normalize({ error: 'off', error_code: 403 })).to include(outcome: 'failed', reason_code: 'disabled')
    end

    it 'fails an empty result instead of drafting from it' do
      expect(described_class.normalize(nil)).to include(outcome: 'failed', reason_code: 'internal_error')
    end
  end

  describe 'reasons for the manager' do
    it 'squishes and bounds the reason of a no_reply' do
      outcome = described_class.no_reply(reason: "  Пациент   поблагодарил.\n", engine: 'agent')

      expect(outcome).to include(outcome: 'no_reply', reason: 'Пациент поблагодарил.', reason_source: 'agent')
    end

    it 'turns a missing reason into a failure: the manager is never given a bare "no reply"' do
      expect(described_class.no_reply(reason: ' ', engine: 'agent'))
        .to include(outcome: 'failed', reason_code: 'invalid_output', detail: 'missing_operator_note')
      expect(described_class.human_needed(reason: nil, engine: 'agent')).to include(outcome: 'failed', reason_code: 'invalid_output')
    end
  end

  describe '.public_result' do
    it 'gives a draft its text, agent, trace and approval cards' do
      outcome = described_class.draft(
        message: 'Здравствуйте!', engine: 'agent', agent: { 'id' => 1 }, captain_trace: { 'version' => 1 },
        follow_up_context: { event_name: 'reply_suggestion' }, pending_actions: [{ 'action_id' => 'a-1' }]
      )

      expect(described_class.public_result(outcome)).to eq(
        'message' => 'Здравствуйте!', 'agent' => { 'id' => 1 }, 'captain_trace' => { 'version' => 1 }, 'suggestion_meta' => nil,
        'pending_actions' => [{ 'action_id' => 'a-1' }], 'follow_up_context' => { event_name: 'reply_suggestion' }
      )
    end

    it 'gives no_reply and human_needed their reason and its source' do
      outcome = described_class.human_needed(reason: 'Нужен врач.', engine: 'agent', reason_source: 'safety', agent: { 'id' => 2 })

      expect(described_class.public_result(outcome))
        .to eq('reason' => 'Нужен врач.', 'reason_source' => 'safety', 'agent' => { 'id' => 2 }, 'pending_actions' => [])
    end

    it 'gives a failure its code only: the error class and the detail stay in llm_events' do
      outcome = described_class.failed('timeout', error_class: 'Timeout::Error', detail: 'hard_limit')

      expect(described_class.public_result(outcome)).to eq('reason_code' => 'timeout')
      expect(described_class.reason_code(outcome)).to eq('timeout')
    end

    it 'gives a cancelled run nothing' do
      expect(described_class.public_result(described_class.cancelled)).to be_nil
    end
  end
end
