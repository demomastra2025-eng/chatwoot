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

    it 'keeps a bounded, explicitly truncated multibyte preview valid for JSON serialization' do
      original = "x#{'я' * 3000}"
      output = described_class.step(
        tool_name: 'list_deal_custom_fields',
        event: 'finish',
        sequence: 1,
        output: original
      ).fetch('output')

      expect(output).to include(
        'truncated' => true,
        'original_bytes' => original.bytesize,
        'sha256' => Digest::SHA256.hexdigest(original)
      )
      expect(output.fetch('preview')).to end_with('…')
      expect(output.fetch('preview').bytesize).to be <= described_class::PREVIEW_LIMIT
      expect(output.fetch('preview')).to be_valid_encoding
      expect { JSON.generate(output) }.not_to raise_error
    end

    it 'keeps safe structured audit facts for a truncated JSON result without presenting the preview as complete JSON', :aggregate_failures do
      result = {
        slots: Array.new(40) do |index|
          {
            slot_id: index + 1,
            starts_at: "2026-09-14T#{format('%02d', index % 24)}:00:00+05:00",
            patient_name: "Пациент #{index}",
            notes: 'я' * 100
          }
        end
      }.to_json
      output = described_class.step(
        tool_name: 'get_scheduling_resource_availability',
        event: 'finish',
        sequence: 1,
        output: result
      ).fetch('output')

      expect(output).to include(
        'truncated' => true,
        'original_bytes' => result.bytesize,
        'content_type' => 'application/json'
      )
      expect(output.dig('json_summary', 'collection_counts')).to eq('slots' => 40)
      expect(output.dig('json_summary', 'fact_count')).to eq(80)
      expect(output.dig('json_summary', 'facts').size).to eq(described_class::SUMMARY_FACT_LIMIT)
      expect(output.dig('json_summary', 'facts_truncated')).to be(true)
      expect(JSON.generate(output['json_summary'])).not_to include('Пациент')
      expect(output.fetch('preview')).not_to include('Пациент')
      expect(output.fetch('preview')).to include('[REDACTED]')
      expect { JSON.parse(output.fetch('preview')) }.to raise_error(JSON::ParserError)
      expect { JSON.generate(output) }.not_to raise_error
    end

    it 'marks the original result as truncated even when redaction makes its preview short' do
      result = { patient_name: 'Я' * 3000 }.to_json
      output = described_class.step(
        tool_name: 'get_appointment',
        event: 'finish',
        sequence: 1,
        output: result
      ).fetch('output')

      expect(output).to include('truncated' => true, 'original_bytes' => result.bytesize)
      expect(output.fetch('preview')).to include('[REDACTED]')
      expect(output.fetch('preview')).not_to include('Я')
    end

    it 'redacts PII from plain text and nested client payloads' do
      plain_output = described_class.step(
        tool_name: 'lookup_patient',
        event: 'finish',
        sequence: 1,
        output: "Call +7 777 123 45 67 or patient@example.kz, IIN 123456789012#{' x' * 2500}"
      ).fetch('output')
      nested_output = described_class.step(
        tool_name: 'lookup_patient',
        event: 'finish',
        sequence: 2,
        output: { client: { name: 'Patient Name' }, status: 'patient@example.kz' }.to_json
      ).fetch('output')

      expect(plain_output.fetch('preview')).not_to match(/777|example|123456789012/)
      expect(nested_output).to eq({ 'client' => '[REDACTED]', 'status' => '[REDACTED]' }.to_json)
    end

    it 'keeps original bytes and SHA for a nested normalized JSON result' do
      original = { slots: Array.new(200) { |index| { slot_id: index, status: 'available' } } }.to_json
      output = described_class.step(
        tool_name: 'get_slots',
        event: 'finish',
        sequence: 1,
        output: Captain::ToolResult.normalize(original)
      ).dig('output', 'message')

      expect(output).to include(
        'original_bytes' => original.bytesize,
        'sha256' => Digest::SHA256.hexdigest(original)
      )
    end

    it 'does not fully parse JSON payloads above the bounded parse limit' do
      original = {
        patient: { name: 'Alice Example' },
        notes: 'private note',
        api_key: 'super-secret',
        items: ['x' * described_class::JSON_PARSE_LIMIT]
      }.to_json

      expect(JSON).not_to receive(:parse)

      output = described_class.step(
        tool_name: 'custom_http',
        event: 'finish',
        sequence: 1,
        output: original
      ).fetch('output')

      expect(output).to include(
        'preview' => '[REDACTED: oversized JSON payload]…',
        'truncated' => true,
        'original_bytes' => original.bytesize,
        'sha256' => Digest::SHA256.hexdigest(original)
      )
      expect(output.fetch('preview')).not_to match(/Alice|private|super-secret/)
      expect(output).not_to have_key('json_summary')

      scalar = ('secret scalar ' * 25_000).to_json
      bom_object = "\uFEFF#{original}"
      scalar_output = described_class.step(tool_name: 'custom_http', event: 'finish', sequence: 2, output: scalar).fetch('output')
      bom_output = described_class.step(tool_name: 'custom_http', event: 'finish', sequence: 3, output: bom_object).fetch('output')

      expect(scalar_output.fetch('preview')).to eq('[REDACTED: oversized JSON payload]…')
      expect(bom_output.fetch('preview')).to eq('[REDACTED: oversized JSON payload]…')
      expect(JSON.generate([scalar_output, bom_output])).not_to match(/secret scalar|Alice|private|super-secret/)
    end

    it 'preserves numeric identifiers, timestamps, and UUIDs while redacting contextual PII' do
      output = described_class.step(
        tool_name: 'book_appointment',
        event: 'finish',
        sequence: 1,
        output: {
          appointment_id: '9876543210',
          provider_command_id: '123456789012',
          operation: '550e8400-e29b-41d4-a716-446655440000',
          starts_at: '1789788600000',
          phone: '87771234567',
          status: 'IIN 123456789012'
        }.to_json
      ).fetch('output')

      expect(JSON.parse(output)).to include(
        'appointment_id' => '9876543210',
        'provider_command_id' => '123456789012',
        'operation' => '550e8400-e29b-41d4-a716-446655440000',
        'starts_at' => '1789788600000',
        'phone' => '[REDACTED]',
        'status' => 'IIN=[REDACTED]'
      )
    end

    it 'bounds summary values, paths, and total serialized output' do
      large_status = { status: 'S' * 250_000 }.to_json
      status_output = described_class.step(
        tool_name: 'probe', event: 'finish', sequence: 1, output: large_status
      ).fetch('output')
      nested = Array.new(90) { |index| "level_#{index}_#{'k' * 900}" }
                    .reverse
                    .reduce(Array.new(25) { |index| { slot_id: index } }) { |memo, key| { key => memo } }
      nested_output = described_class.step(
        tool_name: 'probe', event: 'finish', sequence: 2, output: nested.to_json
      ).fetch('output')

      expect(status_output.dig('json_summary', 'facts', 0, 'value').bytesize)
        .to be <= described_class::SUMMARY_VALUE_LIMIT
      expect(nested_output.dig('json_summary', 'facts').map { |fact| fact.fetch('path').bytesize }.max)
        .to be <= described_class::SUMMARY_PATH_LIMIT
      expect(JSON.generate(status_output).bytesize).to be <= 16 * 1024
      expect(JSON.generate(nested_output).bytesize).to be <= 16 * 1024
    end

    it 'fails closed for BOM-prefixed and deeply nested JSON parse failures' do
      sensitive_json = { api_key: 'super-secret', patient: { name: 'Alice' } }.to_json
      bom_json = "\uFEFF#{sensitive_json}"
      opening = '{"wrapper":' * 101
      closing = '}' * 101
      deep_json = "#{opening}#{sensitive_json}#{closing}"

      outputs = [bom_json, deep_json].map.with_index do |payload, index|
        described_class.step(
          tool_name: 'probe', event: 'finish', sequence: index + 1, output: payload
        ).fetch('output')
      end

      expect(outputs.first).to eq({ api_key: '[REDACTED]', patient: '[REDACTED]' }.to_json)
      expect(outputs.last.fetch('preview')).to eq('[REDACTED: invalid JSON payload]…')
      expect(JSON.generate(outputs)).not_to match(/super-secret|Alice/)
    end

    it 'fails closed when parsed JSON contains values that JSON cannot generate' do
      payloads = ['1e1000000', '{"status":1e1000000}', '[1e1000000]']

      outputs = payloads.map.with_index do |payload, index|
        described_class.step(
          tool_name: 'probe', event: 'finish', sequence: index + 1, output: payload
        ).fetch('output')
      end

      expect(outputs).to all(include('preview' => '[REDACTED: unserializable JSON payload]…', 'truncated' => true))
      expect(outputs.map { |output| output.fetch('sha256') })
        .to eq(payloads.map { |payload| Digest::SHA256.hexdigest(payload) })
    end

    it 'preserves ordinary text that starts like a JSON scalar' do
      payloads = [
        '2 appointments available',
        '2026-09-19 10:00 slot booked',
        '- retry scheduled',
        'true result returned',
        'false result returned',
        'null response from provider'
      ]

      outputs = payloads.map.with_index do |payload, index|
        described_class.step(
          tool_name: 'probe', event: 'finish', sequence: index + 1, output: payload
        ).fetch('output')
      end

      expect(outputs).to eq(payloads)
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

    it 'keeps successful empty results distinct from failed results' do
      empty_success = described_class.step(
        tool_name: 'search_available_slots',
        event: 'finish',
        sequence: 1,
        output: Captain::ToolResult.normalize(nil)
      )
      failure = described_class.step(
        tool_name: 'search_available_slots',
        event: 'failed',
        sequence: 2,
        output: Captain::ToolResult.failure(error: 'provider timeout', retryable: true)
      )

      expect(empty_success['output']).to eq('success' => true)
      expect(failure['output']).to include('success' => false, 'error' => 'provider timeout', 'retryable' => true)
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
