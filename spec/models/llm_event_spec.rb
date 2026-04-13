require 'rails_helper'

RSpec.describe LlmEvent do
  describe 'validations' do
    it { is_expected.to validate_presence_of(:event_name) }
  end

  describe 'associations' do
    it { is_expected.to belong_to(:account).optional }
    it { is_expected.to belong_to(:conversation).optional }
  end

  describe 'scopes' do
    let!(:chat_event) { create(:llm_event, account_id: 1, feature: 'assistant', model: 'gpt-4.1-mini') }
    let!(:blocked_event) do
      create(:llm_event, event_name: 'llm.safety.blocked', feature: 'copilot', blocked: true, account_id: 1)
    end
    let!(:schema_event) do
      create(:llm_event, event_name: 'llm.schema.invalid', feature: 'editor', schema_invalid: true, account_id: 2)
    end

    it 'filters by account and feature' do
      expect(described_class.for_account(1).for_feature('assistant')).to contain_exactly(chat_event)
    end

    it 'filters by session identifier' do
      chat_event.update!(session_id: 'session-1')
      blocked_event.update!(session_id: 'session-2')

      expect(described_class.for_session_id('session-1')).to contain_exactly(chat_event)
    end

    it 'filters by trace identifier stored in the dedicated column' do
      chat_event.update!(trace_id: 'trace-1')
      blocked_event.update!(trace_id: 'trace-2')

      expect(described_class.for_trace_id('trace-1')).to contain_exactly(chat_event)
    end

    it 'returns flagged subsets' do
      expect(described_class.blocked_events).to contain_exactly(blocked_event)
      expect(described_class.schema_invalid_events).to contain_exactly(schema_event)
    end

    it 'filters by semantic event flag' do
      expect(described_class.for_flag('blocked')).to contain_exactly(blocked_event)
      expect(described_class.for_flag('schema_invalid')).to contain_exactly(schema_event)
      expect(described_class.for_flag('unknown')).to include(chat_event, blocked_event, schema_event)
    end
  end
end
