require 'rails_helper'

RSpec.describe Scheduling::Appointments::RetiredFinanceGuard do
  it 'rejects all retired fields in raw or nested payloads, including numeric zero' do
    described_class::RETIRED_FINANCE_PARAMS.each do |field|
      [{ field => 0 }, { 'appointment' => { field => '0' } },
       ActionController::Parameters.new(appointment: { field => 0 })].each do |payload|
        expect { described_class.reject_fields!(payload) }
          .to raise_error(Scheduling::Error) do |error|
            expect(error.code).to eq('RETIRED_FINANCE_FIELDS')
            expect(error.status).to eq(422)
          end
      end
    end
  end

  it 'accepts ordinary top-level and nested appointment fields' do
    expect { described_class.reject_fields!(appointment: { client_comment: 'Note' }) }.not_to raise_error
  end

  it 'keeps the old direct payment operation closed without advertising a Captain or MCP native tool' do
    operation = Captain::Tools::Operations::AppointmentOperations.new(assistant: nil)
    expect { operation.add_payment_to_current_appointment(payment_method: 'cash', amount: 100) }
      .to raise_error(Scheduling::Error) do |error|
        expect(error.code).to eq('RETIRED_FINANCE_MUTATION')
        expect(error.status).to eq(422)
      end
    expect(Captain::ToolRegistry.definition_for('add_appointment_payment')).to be_nil
    expect(Captain::ToolRegistry.tools_for_scope(Captain::ToolAccess::SCOPE_ASSISTANT).pluck(:id))
      .not_to include('add_appointment_payment')
  end
end
