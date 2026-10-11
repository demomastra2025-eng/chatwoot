require 'rails_helper'

RSpec.describe Captain::Tools::Operations::AppointmentOperations do
  let(:assistant) { create(:captain_assistant) }
  let(:resource) { create(:scheduling_resource, account: assistant.account) }
  let(:operations) { described_class.new(assistant: assistant) }

  before { assistant.account.enable_features!('scheduling') }

  it 'proves invalid dates cannot start a mutation' do
    expect(operations).not_to receive(:persist_creation!)
    expect do
      operations.create_appointment(resource_id: resource.id, starts_at: 'not-a-date')
    end.to raise_error(Scheduling::Error) { |error|
      expect(error.code).to eq('INVALID_DATE')
      result = Captain::ToolResult.normalize(Captain::Tools::Agent::AppointmentResult.failure_output(error))
      expect(result.dig(:audit, :mutation_executed)).to be(false)
      expect(result.dig(:audit, :failure_stage)).to eq('tool_arguments')
    }
  end

  it 'does not mark an uncertain error raised after persistence as safe to repeat' do
    expect(operations).to receive(:persist_creation!).once.and_raise(
      Scheduling::Error.new(code: 'INTERNAL_FAILURE', message: 'Unknown outcome', status: :internal_server_error)
    )
    expect do
      operations.create_appointment(resource_id: resource.id, starts_at: 1.day.from_now.iso8601)
    end.to raise_error(Scheduling::Error) { |error|
      expect(Captain::Tools::Agent::AppointmentResult.failure(error).dig(:audit, :mutation_executed)).to be_nil
    }
  end

  it 'identifies an unknown service without attempting a provider mutation' do
    expect(operations).not_to receive(:persist_creation!)
    expect do
      operations.create_appointment(resource_id: resource.id, starts_at: 1.day.from_now.iso8601, service_id: 2_147_483_647)
    end.to raise_error(Scheduling::Error) { |error|
      expect(error.code).to eq('UNKNOWN_SERVICE')
      expect(error.details[:mutation_executed]).to be(false)
    }
  end

  it 'allows correcting a fractional duration that failed before mutation' do
    expect(operations).not_to receive(:persist_creation!)
    expect do
      operations.create_appointment(resource_id: resource.id, starts_at: 1.day.from_now.iso8601, duration_min: 30.5)
    end.to raise_error(Scheduling::Error) { |error|
      expect(error.code).to eq('INVALID_DURATION')
      expect(Captain::Tools::Agent::AppointmentResult.failure_output(error).dig(:audit, :mutation_executed)).to be(false)
    }
  end
end
