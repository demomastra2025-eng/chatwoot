require 'rails_helper'

RSpec.describe KaspiPay::HistoryService do
  let(:hook) { instance_double(Integrations::Hook) }
  let(:client) { instance_double(KaspiPay::Client) }
  let(:service) { described_class.new(hook: hook, client: client) }

  it 'returns normalized operations history data' do
    allow(client).to receive(:operations_history).with(
      end_date: '2026-07-17', last_transaction_date: nil, statement_period_code: 0
    ).and_return('StatusCode' => 0, 'Data' => { 'Operations' => [{ 'Id' => 1 }] })

    expect(service.operations(end_date: '2026-07-17')).to eq('Operations' => [{ 'Id' => 1 }])
  end

  it 'returns operation details and invoice history through the adapter client' do
    allow(client).to receive(:operation_details).with(12, operation_method: 0).and_return('StatusCode' => 0, 'Data' => { 'Id' => 12 })
    allow(client).to receive(:invoice_history).and_return('StatusCode' => 0, 'Data' => [{ 'Id' => 13 }])

    expect(service.operation_details(id: 12)).to eq('Id' => 12)
    expect(service.invoice_history).to eq([{ 'Id' => 13 }])
  end
end
