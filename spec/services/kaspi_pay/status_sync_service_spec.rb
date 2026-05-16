require 'rails_helper'

RSpec.describe KaspiPay::StatusSyncService do
  let(:account) { create(:account) }
  let(:hook) { create(:integrations_hook, :kaspi_pay, account: account) }
  let(:resource) { create(:scheduling_resource, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:service) { create(:scheduling_service, account: account) }
  let(:appointment) do
    create(:scheduling_appointment, account: account, resource: resource, contact: contact, service: service, service_amount: 12_000)
  end
  let(:payment) do
    create(
      :kaspi_pay_payment,
      account: account,
      integration_hook: hook,
      source: appointment,
      amount: 12_000,
      kaspi_operation_id: 'qr-123',
      status: 'pending'
    )
  end
  let(:client) { instance_double(KaspiPay::Client) }

  before do
    account.enable_features!('scheduling', 'scheduling_finance')
    allow(KaspiPay::Client).to receive(:new).with(hook: hook).and_return(client)
  end

  it 'marks a processed QR payment as paid and records native scheduling payment once' do
    allow(client).to receive(:qr_status).with('qr-123').and_return(
      'StatusCode' => 0,
      'Data' => {
        'Status' => 'Processed',
        'StatusDesc' => 'Операция проведена успешно',
        'ReceiptUrl' => 'https://kaspi.kz/receipt/1'
      }
    )

    described_class.new(payment: payment).sync!
    described_class.new(payment: payment.reload).sync!

    expect(payment.reload.status).to eq('paid')
    expect(payment.paid_at).to be_present
    expect(payment.metadata['scheduling_payment_id']).to be_present
    expect(appointment.reload.payment_status).to eq('paid')
    expect(appointment.payments.where(payment_method: 'kaspi_qr', payment_kind: 'payment').count).to eq(1)
  end

  it 'records separate appointment payments for separate Kaspi operations with the same amount' do
    appointment.update!(service_amount: 24_000)
    second_payment = create(
      :kaspi_pay_payment,
      account: account,
      integration_hook: hook,
      source: appointment,
      amount: 12_000,
      kaspi_operation_id: 'qr-456',
      status: 'pending'
    )
    allow(client).to receive(:qr_status).and_return(
      'StatusCode' => 0,
      'Data' => { 'Status' => 'Processed', 'StatusDesc' => 'Операция проведена успешно' }
    )

    described_class.new(payment: payment).sync!
    described_class.new(payment: second_payment).sync!

    expect(appointment.payments.where(payment_method: 'kaspi_qr', payment_kind: 'payment', amount: 12_000).count).to eq(2)
    expect(payment.reload.metadata['scheduling_payment_id']).not_to eq(second_payment.reload.metadata['scheduling_payment_id'])
  end

  it 'marks expired provider statuses as expired without recording scheduling payment' do
    allow(client).to receive(:qr_status).and_return(
      'StatusCode' => 0,
      'Data' => {
        'Status' => 'Expired',
        'StatusDesc' => 'Время оплаты истекло'
      }
    )

    described_class.new(payment: payment).sync!

    expect(payment.reload.status).to eq('expired')
    expect(appointment.reload.payment_status).to eq('awaiting_payment')
  end

  it 'records a conversation activity once when a dialog payment is paid' do
    conversation = create(:conversation, account: account)
    dialog_payment = create(
      :kaspi_pay_payment,
      account: account,
      integration_hook: hook,
      source: conversation,
      amount: 15_000,
      kaspi_operation_id: 'qr-dialog-1',
      status: 'pending'
    )
    allow(client).to receive(:qr_status).with('qr-dialog-1').and_return(
      'StatusCode' => 0,
      'Data' => {
        'Status' => 'Processed',
        'StatusDesc' => 'Операция проведена успешно'
      }
    )

    described_class.new(payment: dialog_payment).sync!
    described_class.new(payment: dialog_payment.reload).sync!

    expect(dialog_payment.reload.status).to eq('paid')
    activities = conversation.messages.where(source_id: "kaspi-pay:payment:#{dialog_payment.id}:paid")
    expect(activities.count).to eq(1)
    expect(activities.first.content).to include('Kaspi Pay')
    expect(activities.first.content_attributes.dig('data', 'status')).to eq('paid')
  end

  it 'expires a dialog payment by QR TTL grace only after Kaspi still reports it pending' do
    conversation = create(:conversation, account: account)
    dialog_payment = create(
      :kaspi_pay_payment,
      account: account,
      integration_hook: hook,
      source: conversation,
      amount: 15_000,
      kaspi_operation_id: 'qr-dialog-expired',
      status: 'pending',
      expires_at: 3.minutes.ago
    )
    allow(client).to receive(:qr_status).with('qr-dialog-expired').and_return('StatusCode' => 0, 'Data' => { 'Status' => 'Pending' })

    described_class.new(payment: dialog_payment).sync!

    expect(client).to have_received(:qr_status).with('qr-dialog-expired')
    expect(dialog_payment.reload.status).to eq('expired')
    expect(dialog_payment.failed_at).to be_present
    expect(dialog_payment.metadata['expired_locally_at']).to be_present
    expect(conversation.messages.where(source_id: "kaspi-pay:payment:#{dialog_payment.id}:expired").count).to eq(1)
  end

  it 'does not locally expire a delayed poll when Kaspi reports the QR as processed' do
    delayed_payment = create(
      :kaspi_pay_payment,
      account: account,
      integration_hook: hook,
      source: create(:conversation, account: account),
      amount: 15_000,
      kaspi_operation_id: 'qr-delayed-paid',
      status: 'pending',
      expires_at: 3.minutes.ago
    )
    allow(client).to receive(:qr_status).with('qr-delayed-paid').and_return(
      'StatusCode' => 0,
      'Data' => { 'Status' => 'Processed', 'ReceiptUrl' => 'https://kaspi.kz/receipt/delayed' }
    )

    described_class.new(payment: delayed_payment).sync!

    expect(delayed_payment.reload.status).to eq('paid')
    expect(delayed_payment.receipt_url).to eq('https://kaspi.kz/receipt/delayed')
  end

  it 'expires a stale pending payment without provider expiry to avoid endless polling' do
    stale_payment = create(
      :kaspi_pay_payment,
      account: account,
      integration_hook: hook,
      source: create(:conversation, account: account),
      amount: 15_000,
      kaspi_operation_id: 'qr-stale',
      status: 'pending',
      created_at: 31.minutes.ago,
      expires_at: nil
    )
    allow(client).to receive(:qr_status).with('qr-stale').and_return('StatusCode' => 0, 'Data' => { 'Status' => 'Pending' })

    described_class.new(payment: stale_payment).sync!

    expect(client).to have_received(:qr_status).with('qr-stale')
    expect(stale_payment.reload.status).to eq('expired')
  end

  it 'uses invoice details for remote invoice payments' do
    invoice_payment = create(
      :kaspi_pay_payment,
      account: account,
      integration_hook: hook,
      source: create(:conversation, account: account),
      payment_type: 'invoice',
      amount: 15_000,
      kaspi_operation_id: 'remote-1',
      status: 'pending'
    )
    allow(client).to receive(:invoice_details).with('remote-1').and_return(
      'StatusCode' => 0,
      'Data' => { 'Status' => 'Processed', 'StatusDesc' => 'Платеж успешно совершен' }
    )

    described_class.new(payment: invoice_payment).sync!

    expect(invoice_payment.reload.status).to eq('paid')
  end
end
