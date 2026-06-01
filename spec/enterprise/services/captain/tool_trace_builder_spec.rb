require 'rails_helper'

RSpec.describe Captain::ToolTraceBuilder do
  describe '.step' do
    it 'builds a canonical trace step with input and output details' do
      expect(
        described_class.step(
          tool_name: 'search_documentation',
          event: 'finish',
          sequence: 1,
          input: { query: 'apartments', api_token: 'x' },
          output: { total: 2 }
        )
      ).to eq(
        {
          'id' => 'search_documentation:finish:1',
          'type' => 'captain_tool_event',
          'tool_name' => 'search_documentation',
          'event' => 'finish',
          'status' => 'finish',
          'content' => 'Completed search_documentation',
          'input' => { 'query' => 'apartments', 'api_token' => '[REDACTED]' },
          'output' => { 'total' => 2 }
        }
      )
    end

    it 'keeps tool call identifiers sequence-safe for repeated progress events' do
      expect(
        described_class.step(
          tool_name: 'search_documentation',
          event: 'progress',
          sequence: 3,
          tool_call_id: 'call-1'
        )
      ).to include('id' => 'search_documentation:progress:3:call-1')
    end

    it 'keeps canonical grouped trace metadata on the step when provided' do
      expect(
        described_class.step(
          tool_name: 'update_deal',
          event: 'complete',
          sequence: 2,
          tool_call_id: 'call-1',
          mutation: true,
          idempotency_key: 'deal-1:update',
          current_agent: 'CRM',
          openrouter_generation_id: 'gen-1'
        )
      ).to include(
        'tool_call_id' => 'call-1',
        'mutation' => true,
        'idempotency_key' => 'deal-1:update',
        'current_agent' => 'CRM',
        'openrouter_generation_id' => 'gen-1'
      )
    end

    it 'keeps legacy complete events readable as finish status' do
      expect(
        described_class.step(
          tool_name: 'search_documentation',
          event: 'complete',
          sequence: 2
        )
      ).to include(
        'event' => 'complete',
        'status' => 'finish',
        'content' => 'Completed search_documentation'
      )
    end
  end

  describe '.payload' do
    it 'wraps steps into a stable captain trace payload' do
      steps = [
        described_class.step(
          tool_name: 'search_documentation',
          event: 'complete',
          sequence: 2
        )
      ]

      expect(described_class.payload(steps)).to eq(
        {
          'version' => 1,
          'tool_steps' => steps,
          'tool_calls' => [
            {
              'tool_call_id' => 'trace-1',
              'tool_name' => 'search_documentation',
              'status' => 'completed'
            }
          ]
        }
      )
    end

    it 'groups started and completed steps into a single canonical tool call' do
      steps = [
        described_class.step(
          tool_name: 'update_deal',
          event: 'start',
          sequence: 1,
          tool_call_id: 'call-1',
          input: { title: 'Хлопок', api_key: 'secret' },
          started_at: '2026-05-31T10:00:00Z',
          mutation: true
        ),
        described_class.step(
          tool_name: 'update_deal',
          event: 'complete',
          sequence: 2,
          tool_call_id: 'call-1',
          output: { amount: 180_000 },
          finished_at: '2026-05-31T10:00:01Z',
          duration_ms: 1000,
          mutation: true,
          idempotency_key: 'deal-533:update'
        )
      ]

      expect(described_class.payload(steps)['tool_calls']).to eq(
        [
          {
            'tool_call_id' => 'call-1',
            'tool_name' => 'update_deal',
            'status' => 'completed',
            'started_at' => '2026-05-31T10:00:00Z',
            'completed_at' => '2026-05-31T10:00:01Z',
            'duration_ms' => 1000,
            'input' => { 'title' => 'Хлопок', 'api_key' => '[REDACTED]' },
            'output' => { 'amount' => 180_000 },
            'mutation' => true,
            'idempotency_key' => 'deal-533:update'
          }
        ]
      )
    end

    it 'marks unfinished started tools as partial' do
      steps = [
        described_class.step(
          tool_name: 'search_deals',
          event: 'start',
          sequence: 1,
          input: { query: 'Хлопок' }
        )
      ]

      expect(described_class.payload(steps)['tool_calls']).to contain_exactly(
        include(
          'tool_name' => 'search_deals',
          'status' => 'partial',
          'input' => { 'query' => 'Хлопок' }
        )
      )
    end

    it 'groups failed tool calls and preserves redacted error payloads' do
      steps = [
        described_class.step(
          tool_name: 'search_deals',
          event: 'failed',
          sequence: 1,
          tool_call_id: 'call-err',
          error: { message: 'timeout', access_token: 'secret' }
        )
      ]

      expect(described_class.payload(steps)['tool_calls']).to contain_exactly(
        include(
          'tool_call_id' => 'call-err',
          'tool_name' => 'search_deals',
          'status' => 'failed',
          'error' => { 'message' => 'timeout', 'access_token' => '[REDACTED]' }
        )
      )
    end

    it 'returns nil when there are no steps' do
      expect(described_class.payload([])).to be_nil
    end

    it 'separates native reasoning from structured and system fallback reasoning' do
      payload = described_class.payload(
        [],
        native_reasoning: {
          text: 'Model-native reasoning text.',
          signature: 'sig_123',
          details: [{ 'type' => 'reasoning.text', 'text' => 'detail' }],
          source: 'openrouter'
        },
        structured_reasoning: 'Captain schema explanation.',
        system_fallback_reason: 'Deterministic fallback after schema failure.'
      )

      expect(payload).to eq(
        'version' => 1,
        'native_reasoning' => {
          'text' => 'Model-native reasoning text.',
          'signature' => 'sig_123',
          'details' => [{ 'type' => 'reasoning.text', 'text' => 'detail' }],
          'source' => 'openrouter'
        },
        'structured_reasoning' => 'Captain schema explanation.',
        'system_fallback_reason' => 'Deterministic fallback after schema failure.'
      )
    end
  end
end
