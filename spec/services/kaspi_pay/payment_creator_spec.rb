require 'rails_helper'

RSpec.describe KaspiPay::PaymentCreator do
  let(:account) { create(:account) }
  let(:hook) { create(:integrations_hook, :kaspi_pay, account: account) }
  let(:resource) { create(:scheduling_resource, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:service) { create(:scheduling_service, account: account) }
  let(:appointment) do
    create(:scheduling_appointment, account: account, resource: resource, contact: contact, service: service, service_amount: 15_000)
  end
  let(:client) { instance_double(KaspiPay::Client) }

  before do
    allow(KaspiPay::Client).to receive(:new).with(hook: hook).and_return(client)
    allow(KaspiPay::StatusPollJob).to receive(:perform_later)
  end

  it 'creates an account-scoped QR payment and schedules status polling' do
    allow(client).to receive(:create_qr).and_return(
      'StatusCode' => 0,
      'Data' => {
        'QrOperationId' => 'qr-123',
        'QrToken' => 'https://pay.kaspi.kz/pay/token',
        'ExpireDate' => 10.minutes.from_now.iso8601,
        'Amount' => 15_000,
        'ReceiptUrl' => 'https://kaspi.kz/receipt/1'
      }
    )

    payment = described_class.new(
      hook: hook,
      source: appointment,
      amount: 15_000,
      idempotency_key: 'appointment-1-payment'
    ).create_qr!

    expect(payment).to be_persisted
    expect(payment.account).to eq(account)
    expect(payment.source).to eq(appointment)
    expect(payment.payment_type).to eq('qr')
    expect(payment.status).to eq('pending')
    expect(payment.kaspi_operation_id).to eq('qr-123')
    expect(payment.qr_token).to eq('https://pay.kaspi.kz/pay/token')
    expect(KaspiPay::StatusPollJob).to have_received(:perform_later).with(payment.id)
  end

  it 'persists the requested amount when Kaspi echoes a zero-like provider amount' do
    allow(client).to receive(:create_qr).and_return(
      'StatusCode' => 0,
      'Data' => {
        'QrOperationId' => 'qr-zero-echo',
        'QrToken' => 'https://pay.kaspi.kz/pay/token',
        'Amount' => '0.00'
      }
    )

    payment = described_class.new(
      hook: hook,
      source: appointment,
      amount: 100,
      idempotency_key: 'zero-echo-payment'
    ).create_qr!

    expect(payment).to be_persisted
    expect(payment.amount).to eq(100)
    expect(payment.metadata['Amount']).to eq('0.00')
  end

  it 'returns existing payment for the same account idempotency key without creating a duplicate' do
    existing = create(:kaspi_pay_payment, account: account, integration_hook: hook, idempotency_key: 'same-key')
    allow(client).to receive(:create_qr)

    payment = described_class.new(
      hook: hook,
      source: appointment,
      amount: 15_000,
      idempotency_key: 'same-key'
    ).create_qr!

    expect(payment).to eq(existing)
    expect(client).not_to have_received(:create_qr)
  end

  it 'serializes idempotent QR creation with an account lock before calling Kaspi' do
    allow(hook).to receive(:account).and_return(account)
    expect(account).to receive(:with_lock).and_call_original
    allow(client).to receive(:create_qr).and_return(
      'StatusCode' => 0,
      'Data' => {
        'QrOperationId' => 'qr-locked',
        'QrToken' => 'https://pay.kaspi.kz/pay/locked-token',
        'Amount' => 15_000
      }
    )

    payment = described_class.new(
      hook: hook,
      source: appointment,
      amount: 15_000,
      idempotency_key: 'locked-key'
    ).create_qr!

    expect(payment.kaspi_operation_id).to eq('qr-locked')
    expect(client).to have_received(:create_qr).once
  end

  it 'rejects QR responses without operation id or payment token' do
    allow(client).to receive(:create_qr).and_return('StatusCode' => 0, 'Data' => { 'Amount' => 15_000 })

    expect do
      described_class.new(
        hook: hook,
        source: appointment,
        amount: 15_000,
        idempotency_key: 'invalid-response'
      ).create_qr!
    end.to raise_error(KaspiPay::Error) { |error| expect(error.code).to eq('QR_RESPONSE_INVALID') }
  end

  it 'records a native conversation activity when QR is created from a reply box' do
    conversation = create(:conversation, account: account)
    allow(client).to receive(:create_qr).and_return(
      'StatusCode' => 0,
      'Data' => {
        'QrOperationId' => 'qr-conversation-1',
        'QrToken' => 'https://pay.kaspi.kz/pay/conversation-token',
        'ExpireDate' => 10.minutes.from_now.iso8601,
        'Amount' => 15_000
      }
    )

    payment = described_class.new(
      hook: hook,
      source: conversation,
      amount: 15_000,
      idempotency_key: 'conversation-payment'
    ).create_qr!

    activity = conversation.messages.find_by(source_id: "kaspi-pay:payment:#{payment.id}:created")
    expect(activity).to be_present
    expect(activity.message_type).to eq('activity')
    expect(activity.content).to include('Kaspi Pay')
    expect(activity.content_attributes.dig('data', 'type')).to eq('kaspi_pay_payment')
    expect(activity.content_attributes.dig('data', 'payment_id')).to eq(payment.id)
  end

  it 'rejects QR creation with a non-QR payment type before calling Kaspi' do
    allow(client).to receive(:create_qr)

    expect do
      described_class.new(
        hook: hook,
        source: appointment,
        amount: 15_000,
        idempotency_key: 'invalid-type',
        payment_type: 'wire'
      ).create_qr!
    end.to raise_error(KaspiPay::Error) { |error| expect(error.code).to eq('INVALID_PAYMENT_TYPE') }
    expect(client).not_to have_received(:create_qr)
  end

  it 'creates a remote invoice payment and schedules status polling' do
    conversation = create(:conversation, account: account)
    allow(client).to receive(:create_invoice).and_return(
      'StatusCode' => 0,
      'Data' => {
        'Id' => 'remote-123',
        'Amount' => 12_000,
        'ReceiptUrl' => 'https://kaspi.kz/remote/123',
        'OrderNumber' => 'order-123',
        'Status' => 'RemotePaymentCreated'
      }
    )

    payment = described_class.new(
      hook: hook,
      source: conversation,
      amount: 12_000,
      idempotency_key: 'invoice-payment',
      payment_type: 'invoice',
      phone_number: '77011234567',
      comment: 'Order 123'
    ).create_invoice!

    expect(client).to have_received(:create_invoice).with(phone_number: '77011234567', amount: 12_000, comment: 'Order 123')
    expect(payment.payment_type).to eq('invoice')
    expect(payment.kaspi_operation_id).to eq('remote-123')
    expect(payment.kaspi_order_number).to eq('order-123')
    expect(payment.receipt_url).to eq('https://kaspi.kz/remote/123')
    expect(KaspiPay::StatusPollJob).to have_received(:perform_later).with(payment.id)
  end
end
