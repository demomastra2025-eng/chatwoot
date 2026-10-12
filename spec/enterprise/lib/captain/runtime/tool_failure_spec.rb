require 'rails_helper'

RSpec.describe Captain::Runtime::ToolFailure do
  def failure(retryable: nil, audit: nil, data: nil, error: 'The tool failed')
    Captain::ToolResult.failure(error: error, retryable: retryable, audit: audit, data: data)
  end

  describe '.classify' do
    it 'is nil for a success' do
      expect(described_class.classify(Captain::ToolResult.success(data: { appointment_id: 1 }))).to be_nil
      expect(described_class.classify('ok')).to be_nil
      expect(described_class.classify(nil)).to be_nil
    end

    context 'when the result declares its class' do
      it 'takes the declaration from the audit, whatever retryable says' do
        expect(described_class.classify(failure(retryable: true, audit: { error_class: 'technical' }))).to eq('technical')
        expect(described_class.classify(failure(retryable: false, audit: { error_class: 'business' }))).to eq('business')
      end

      it 'takes the declaration from the data and from a top-level key of the result' do
        expect(described_class.classify(failure(retryable: false, data: { error_class: 'business' }))).to eq('business')
        expect(described_class.classify({ success: false, error: 'x', error_class: 'technical' })).to eq('technical')
      end

      it 'takes the declaration from a compact JSON failure' do
        expect(described_class.classify('{"success":false,"reason":"time_taken","error_class":"technical"}')).to eq('technical')
        expect(described_class.classify('{"success":false,"reason":"internal_failure","error_class":"business"}')).to eq('business')
      end

      it 'ignores a class that is neither technical nor business' do
        expect(described_class.classify(failure(retryable: false, audit: { error_class: 'RuntimeError' }))).to eq('technical')
      end
    end

    context 'without a declaration' do
      it 'leaves a failure that is not final to the agent' do
        expect(described_class.classify(failure(retryable: true))).to eq('business')
        expect(described_class.classify(failure(retryable: nil))).to eq('business')
        expect(described_class.classify('ERROR: Contact not found')).to eq('business')
      end

      it 'treats a final failure as technical' do
        expect(described_class.classify(failure(retryable: false))).to eq('technical')
        expect(described_class.classify(failure(retryable: false, audit: { failure_stage: 'tool_execution' }))).to eq('technical')
      end

      it 'treats a final failure as business when the model can fix the arguments' do
        expect(described_class.classify(failure(retryable: false, audit: { failure_stage: 'tool_arguments' }))).to eq('business')
        expect(described_class.classify(failure(retryable: false, audit: { failure_stage: 'validation' }))).to eq('business')
      end

      it 'treats a final failure of a runtime guard as business' do
        %w[duplicate_failed_tool_call mutation_retry_blocked tool_attempt_limit parallel_mutating_tool_call tool_not_bound].each do |reason|
          expect(described_class.classify(failure(retryable: false, audit: { failure_reason: reason }))).to eq('business')
        end
      end

      it 'treats the compact answers of the scheduling tools by their reason' do
        %w[time_taken not_found validation_error schedule_not_open invalid_date unknown_service].each do |reason|
          expect(described_class.classify(JSON.generate(success: false, reason: reason))).to eq('business')
        end
        %w[provider_unavailable internal_failure staff_will_help].each do |reason|
          expect(described_class.classify(JSON.generate(success: false, reason: reason))).to eq('technical')
        end
      end

      it 'keeps a booking that waits for the confirmation of the provider out of the failures' do
        pending = JSON.generate(success: false, reason: 'pending_provider_confirmation', appointment_id: 7, provider_confirmed: false,
                                provider_confirmation_operation: 'create_reception', provider_confirmation_scope: 'medelement')

        expect(described_class.classify(pending)).to eq('business')
        expect(described_class.pending?(pending)).to be(true)
        expect(described_class.outcome(pending)).to eq('success')
      end

      it 'reads a failure that a tool rendered as text' do
        rendered = Captain::ToolResult.failure_output(error: 'Provider rejected the call', retryable: false)
        record_missing = Captain::ToolResult.failure_output(error: 'Record is not available', data: { code: 'record_not_available' },
                                                            retryable: false)
        conflict = Captain::ToolResult.failure_output(error: 'Taken', data: { code: 'SLOT_CONFLICT' }, retryable: false)

        expect(described_class.classify(rendered)).to eq('technical')
        expect(described_class.classify(record_missing)).to eq('business')
        expect(described_class.classify(conflict)).to eq('business')
      end

      it 'treats the results of the Playground policy as answers' do
        blocked = Captain::ToolResult.failure(error: 'Review and confirm this exact real action in Playground', retryable: false,
                                              data: { code: 'playground_confirmation_required', delivered: false })

        expect(described_class.classify(blocked)).to eq('business')
      end
    end
  end

  describe '.outcome' do
    it 'is success for a success, also a pending one' do
      expect(described_class.outcome(Captain::ToolResult.success(data: { id: 1 }))).to eq('success')
      pending = { success: true, data: { provider_confirmation_required: true, provider_confirmed: false } }

      expect(described_class.outcome(pending)).to eq('success')
    end

    it 'is not_executed for a call that was rejected and for a business answer' do
      expect(described_class.outcome(failure(retryable: false, audit: { mutation_executed: false, failure_stage: 'tool_execution' }))).to eq('not_executed')
      expect(described_class.outcome(JSON.generate(success: false, reason: 'time_taken'))).to eq('not_executed')
      expect(described_class.outcome(failure(retryable: false, audit: { error_class: 'business' }))).to eq('not_executed')
    end

    it 'is unknown for every other failure, because the write may have happened' do
      expect(described_class.outcome(failure(retryable: false))).to eq('unknown')
      expect(described_class.outcome(failure(retryable: true))).to eq('unknown')
      expect(described_class.outcome(failure(retryable: false, audit: { error_class: 'technical' }))).to eq('unknown')
    end
  end

  describe '.annotation_tool?' do
    it 'recognises the tools that only annotate the conversation, also with a prefix' do
      expect(described_class.annotation_tool?('add_private_note')).to be(true)
      expect(described_class.annotation_tool?('mcp__crm__update_priority')).to be(true)
      expect(described_class.annotation_tool?('create_appointment')).to be(false)
    end
  end

  describe '.summary' do
    it 'names the tool, the kind and the codes and nothing else' do
      result = failure(retryable: false, error: 'Patient Айгуль Нурлан, +7 701 000 00 00 rejected', audit: { failure_stage: 'tool_execution', failure_reason: 'provider_unavailable' })

      summary = described_class.summary('mcp__medelement__create_appointment', result)

      expect(summary).to eq('tool' => 'create_appointment', 'kind' => 'technical', 'stage' => 'tool_execution', 'reason' => 'provider_unavailable')
      expect(summary.to_json).not_to include('Айгуль', '701')
    end
  end
end
