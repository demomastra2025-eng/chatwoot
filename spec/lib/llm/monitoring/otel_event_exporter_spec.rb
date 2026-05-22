# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::Monitoring::OtelEventExporter do
  let(:started_at) { 2.seconds.ago }
  let(:finished_at) { Time.current }
  let(:span) { instance_spy(OpenTelemetry::Trace::Span) }
  let(:tracer) { instance_double(OpenTelemetry::Trace::Tracer) }
  let(:payload) do
    {
      'account_id' => 1,
      'assistant_id' => 2,
      'conversation_id' => 3,
      'conversation_display_id' => 44,
      'copilot_thread_id' => 5,
      'feature' => 'assistant',
      'runtime_mode' => 'captain_runtime',
      'model' => 'gpt-4.1-mini',
      'provider' => 'openai',
      'prompt_tokens' => 12,
      'completion_tokens' => 34,
      'total_tokens' => 46,
      'tool_name' => 'search_deals',
      'schema_name' => 'CaptainResponse',
      'trace_id' => 'trace-1',
      'session_id' => 'session-1',
      'project_case_id' => 'crm.lookup_tool',
      'error_code' => 'provider_unavailable',
      'canonical_event_name' => 'llm.run.complete',
      'event_name_alias' => 'llm.run.failed',
      'prompt' => 'raw customer prompt must not be exported',
      'messages' => [{ role: 'user', content: 'raw message must not be exported' }],
      'content' => 'raw output must not be exported'
    }
  end

  let(:exported_attributes) { {} }

  before do
    allow(ChatwootApp).to receive(:otel_enabled?).and_return(true)
    allow(OpentelemetryConfig).to receive(:tracer).and_return(tracer)
    allow(span).to receive(:set_attribute) { |key, value| exported_attributes[key] = value }
    allow(tracer).to receive(:in_span).and_yield(span)
  end

  describe '.export_notification' do
    it 'maps OneLink event payloads into safe GenAI and product OTel attributes' do
      with_modified_env('LLM_EVENT_OTEL_EXPORT_ENABLED' => 'true') do
        described_class.export_notification(
          event_name: 'llm.run.complete',
          started_at: started_at,
          finished_at: finished_at,
          payload: payload
        )
      end

      expect(tracer).to have_received(:in_span).with('llm.run.complete')
      expect(exported_attributes).to include(
        'gen_ai.provider.name' => 'openai',
        'gen_ai.request.model' => 'gpt-4.1-mini',
        'gen_ai.usage.input_tokens' => 12,
        'gen_ai.usage.output_tokens' => 34,
        'gen_ai.usage.total_tokens' => 46,
        'gen_ai.response.error_code' => 'provider_unavailable',
        'one_link.event.name' => 'llm.run.complete',
        'one_link.event.alias' => 'llm.run.failed',
        'one_link.feature' => 'assistant',
        'one_link.runtime_mode' => 'captain_runtime',
        'one_link.project_case_id' => 'crm.lookup_tool',
        'one_link.tool.name' => 'search_deals',
        'one_link.schema.name' => 'CaptainResponse'
      )
      expect(exported_attributes.keys).not_to include(
        a_string_matching(/prompt|messages|content/),
        'gen_ai.prompt.0.content',
        'gen_ai.completion.0.content'
      )
    end

    it 'does nothing when event OTel export is disabled' do
      with_modified_env('LLM_EVENT_OTEL_EXPORT_ENABLED' => nil) do
        described_class.export_notification(
          event_name: 'llm.chat.complete',
          started_at: started_at,
          finished_at: finished_at,
          payload: payload
        )
      end

      expect(OpentelemetryConfig).not_to have_received(:tracer)
      expect(tracer).not_to have_received(:in_span)
    end

    it 'swallows exporter errors so AI runtime is not affected by OTLP failures' do
      allow(tracer).to receive(:in_span).and_raise(StandardError, 'otlp down')

      expect do
        with_modified_env('LLM_EVENT_OTEL_EXPORT_ENABLED' => 'true') do
          described_class.export_notification(
            event_name: 'llm.chat.complete',
            started_at: started_at,
            finished_at: finished_at,
            payload: payload
          )
        end
      end.not_to raise_error
    end

    it 'applies the optional event-export sample rate' do
      with_modified_env('LLM_EVENT_OTEL_EXPORT_ENABLED' => 'true', 'LLM_EVENT_OTEL_SAMPLE_RATE' => '0') do
        described_class.export_notification(
          event_name: 'llm.chat.complete',
          started_at: started_at,
          finished_at: finished_at,
          payload: payload
        )
      end

      expect(tracer).not_to have_received(:in_span)
    end

    it 'samples fractional event-export rates' do
      allow(described_class).to receive(:rand).and_return(0.7, 0.2)

      with_modified_env('LLM_EVENT_OTEL_EXPORT_ENABLED' => 'true', 'LLM_EVENT_OTEL_SAMPLE_RATE' => '0.5') do
        2.times do
          described_class.export_notification(
            event_name: 'llm.chat.complete',
            started_at: started_at,
            finished_at: finished_at,
            payload: payload
          )
        end
      end

      expect(tracer).to have_received(:in_span).once
    end

    it 'fails closed for malformed event-export sample rates' do
      with_modified_env('LLM_EVENT_OTEL_EXPORT_ENABLED' => 'true', 'LLM_EVENT_OTEL_SAMPLE_RATE' => 'not-a-number') do
        described_class.export_notification(
          event_name: 'llm.chat.complete',
          started_at: started_at,
          finished_at: finished_at,
          payload: payload
        )
      end

      expect(tracer).not_to have_received(:in_span)
    end
  end
end
