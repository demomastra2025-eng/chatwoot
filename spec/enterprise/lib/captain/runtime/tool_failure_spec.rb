require 'rails_helper'

RSpec.describe Captain::Runtime::ToolFailure do
  def failure(retryable: nil, audit: nil, data: nil, error: 'The tool failed')
    Captain::ToolResult.failure(error: error, retryable: retryable, audit: audit, data: data)
  end

  describe '.facts' do
    it 'reads the fields of a JSON text, of a hash and of the data of a normalized result as one hash with string keys' do
      expect(described_class.facts('{"title":"Имплантация","deal":{"id":8}}')).to include('title' => 'Имплантация', 'deal' => { 'id' => 8 })
      expect(described_class.facts({ doctor_name: 'Иванов', local_time: '11:00' })).to include('doctor_name' => 'Иванов', 'local_time' => '11:00')
      expect(described_class.facts(Captain::ToolResult.success(data: { appointment_id: 1 }))).to include('appointment_id' => 1)
    end

    it 'adds the audit of the result, and is empty for a result without fields' do
      expect(described_class.facts(Captain::ToolResult.success(audit: { mutation_executed: true }))).to include('mutation_executed' => true)
      expect(described_class.facts('ok')).to eq({})
      expect(described_class.facts(nil)).to eq({})
    end
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

  # The failure of a scheduling read tool, as the tool renders it (Captain::Tools::Copilot::SchedulingQueryValidation).
  def scheduling_read_failure(code: nil, status: :unprocessable_content, reason: nil, raised: nil)
    reader = Class.new { include Captain::Tools::Copilot::SchedulingQueryValidation }.new
    raised ||= Scheduling::Error.new(code: code, message: 'The tool failed', status: status, details: { reason: reason }.compact)
    reader.send(:scheduling_tool_failure, raised)
  end

  describe '.classify for the failures of the scheduling read tools' do
    it 'takes a specialist that does not exist or cannot be scheduled, and malformed ids, for business answers the agent fixes' do
      {
        'RESOURCE_NOT_FOUND' => [:not_found, 'unknown_resource'],
        'INVALID_RESOURCE_IDS' => [:unprocessable_content, 'invalid_resource_ids'],
        'SERVICE_NOT_AVAILABLE_FOR_RESOURCE' => [:unprocessable_content, 'service_not_linked'],
        'INVALID_DATE_RANGE' => [:unprocessable_content, 'invalid_date_range'],
        'INVALID_SERVICE_ID' => [:unprocessable_content, 'invalid_service_id']
      }.each do |code, (status, reason)|
        expect(described_class.classify(scheduling_read_failure(code: code, status: status, reason: reason))).to eq('business'), code
      end
    end

    it 'takes an internal failure and a failure of the provider for technical ones, whatever the status says' do
      expect(described_class.classify(scheduling_read_failure(raised: RuntimeError.new('boom')))).to eq('technical')
      expect(described_class.classify(scheduling_read_failure(code: 'INTERNAL_FAILURE', status: :internal_server_error, reason: 'internal_failure')))
        .to eq('technical')
      expect(described_class.classify(scheduling_read_failure(code: 'PROVIDER_UNAVAILABLE'))).to eq('technical')
      expect(described_class.classify(scheduling_read_failure(code: 'MEDELEMENT_AVAILABILITY_UNVERIFIED'))).to eq('technical')
      expect(described_class.classify(scheduling_read_failure(code: 'ANYTHING', status: :service_unavailable))).to eq('technical')
    end

    it 'declares the class in the failure, so that the declaration and not the shape of the result decides' do
      rendered = scheduling_read_failure(code: 'RESOURCE_NOT_FOUND', status: :not_found, reason: 'unknown_resource')

      expect(described_class.describe(rendered)).to include(declared: 'business', failure: true, retryable: false)
    end
  end

  describe '.business_answer?' do
    it 'is true for a failure that is an answer of the tool and changed nothing' do
      expect(described_class.business_answer?(JSON.generate(success: false, reason: 'time_taken'))).to be(true)
      expect(described_class.business_answer?(failure(retryable: false, audit: { error_class: 'business' }))).to be(true)
      expect(described_class.business_answer?(Captain::ToolResult.failure_output(error: 'Taken', data: { code: 'SLOT_CONFLICT' }, retryable: false))).to be(true)
    end

    it 'is false for a success, a pending write, a technical failure and a bare rejection stage' do
      expect(described_class.business_answer?(Captain::ToolResult.success(data: { id: 1 }))).to be(false)
      expect(described_class.business_answer?(JSON.generate(success: false, reason: 'pending_provider_confirmation'))).to be(false)
      expect(described_class.business_answer?(JSON.generate(success: false, reason: 'staff_will_help'))).to be(false)
      expect(described_class.business_answer?(failure(retryable: false, audit: { error_class: 'technical', failure_reason: 'time_taken' }))).to be(false)
      expect(described_class.business_answer?(failure(retryable: false, audit: { failure_stage: 'tool_arguments' }))).to be(false)
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
