require 'rails_helper'

RSpec.describe 'Captain Kaspi Pay tools' do
  let(:account) { create(:account) }
  let(:admin) { create(:user, :administrator, account: account) }
  let(:agent) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:hook) { create(:integrations_hook, :kaspi_pay, account: account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:client) { instance_double(KaspiPay::Client) }

  before do
    hook
    allow(KaspiPay::Client).to receive(:new).with(hook: hook).and_return(client)
    allow(KaspiPay::StatusPollJob).to receive(:perform_later)
  end

  describe Captain::Tools::CreateKaspiPayPaymentTool do
    it 'creates a QR payment only for the current customer conversation' do
      allow(client).to receive(:create_qr).and_return(
        'StatusCode' => 0,
        'Data' => {
          'QrOperationId' => 'agent-qr-1',
          'QrToken' => 'https://pay.kaspi.kz/pay/agent-token',
          'ExpireDate' => 10.minutes.from_now.iso8601,
          'Amount' => 12_000
        }
      )
      tool = described_class.new(assistant)
      tool_context = Struct.new(:state).new({ conversation: { id: conversation.id } })

      payload = JSON.parse(tool.perform(tool_context, amount: 12_000))

      expect(payload['action']).to eq('create_kaspi_pay_payment')
      expect(payload.dig('payment', 'amount')).to eq(12_000)
      expect(payload.dig('payment', 'qr_token')).to eq('https://pay.kaspi.kz/pay/agent-token')
      expect(payload.dig('payment', 'source')).to include('type' => 'Conversation', 'id' => conversation.id)
      expect(KaspiPay::StatusPollJob).to have_received(:perform_later).with(payload.dig('payment', 'id'))
    end
  end

  describe Captain::Tools::GetKaspiPayPaymentStatusTool do
    it 'rejects a payment from another conversation in customer-facing scope' do
      other_conversation = create(:conversation, account: account)
      payment = create(:kaspi_pay_payment, account: account, integration_hook: hook, source: other_conversation)
      tool = described_class.new(assistant)
      tool_context = Struct.new(:state).new({ conversation: { id: conversation.id } })

      result = tool.perform(tool_context, payment_id: payment.id)

      expect(result).to include('ERROR: ActiveRecord::RecordNotFound')
      expect(result).to include('current conversation')
    end

    it 'syncs only the current conversation payment when requested' do
      payment = create(:kaspi_pay_payment, account: account, integration_hook: hook, source: conversation, kaspi_operation_id: 'qr-current')
      allow(client).to receive(:qr_status).with('qr-current').and_return(
        'StatusCode' => 0,
        'Data' => { 'Status' => 'paid', 'ReceiptUrl' => 'https://kaspi.kz/receipt/current' }
      )
      tool = described_class.new(assistant)
      tool_context = Struct.new(:state).new({ conversation: { id: conversation.id } })

      payload = JSON.parse(tool.perform(tool_context, payment_id: payment.id, sync: true))

      expect(payload['action']).to eq('get_kaspi_pay_payment_status')
      expect(payload.dig('payment', 'status')).to eq('paid')
      expect(payment.reload.status).to eq('paid')
    end
  end

  describe Captain::Tools::Copilot::CreateKaspiPayPaymentService do
    it 'creates an account-scoped payment for an administrator assistant' do
      allow(client).to receive(:create_qr).and_return(
        'StatusCode' => 0,
        'Data' => {
          'QrOperationId' => 'assistant-qr-1',
          'QrToken' => 'https://pay.kaspi.kz/pay/assistant-token',
          'Amount' => 20_000
        }
      )
      service = described_class.new(assistant, user: admin, conversation: conversation)

      payload = JSON.parse(service.execute(conversation_id: conversation.display_id, amount: 20_000))

      expect(payload['action']).to eq('create_kaspi_pay_payment')
      expect(payload.dig('payment', 'source', 'display_id')).to eq(conversation.display_id)
      expect(payload.dig('payment', 'amount')).to eq(20_000)
    end

    it 'blocks non-admin account users from assistant-scope payment creation' do
      service = described_class.new(assistant, user: agent, conversation: conversation)

      expect { service.execute(conversation_id: conversation.display_id, amount: 20_000) }
        .to raise_error(ArgumentError, /administrator/)
    end
  end

  describe Captain::Tools::Copilot::SearchKaspiPayPaymentsService do
    it 'returns only current-account payments and never exposes hook secrets' do
      create(:kaspi_pay_payment, account: account, integration_hook: hook, source: conversation, amount: 15_000, status: 'paid')
      other_account = create(:account)
      other_hook = create(:integrations_hook, :kaspi_pay, account: other_account)
      create(:kaspi_pay_payment, account: other_account, integration_hook: other_hook, amount: 99_000)
      service = described_class.new(assistant, user: admin, conversation: conversation)

      payload = JSON.parse(service.execute(status: 'paid'))

      expect(payload['total_count']).to eq(1)
      expect(payload.dig('payments', 0, 'amount')).to eq(15_000)
      expect(payload.to_json).not_to include('vtoken_secret')
      expect(payload.to_json).not_to include('encrypted-secret')
    end
  end

  describe Captain::Tools::Copilot::GetKaspiPayIntegrationStatusService do
    it 'returns safe integration metadata without secrets for an administrator' do
      service = described_class.new(assistant, user: admin)

      payload = JSON.parse(service.execute)

      expect(payload['connected']).to be(true)
      expect(payload.dig('hook', 'metadata')).to include('organization_id' => 'org-1', 'org_name' => 'Test Merchant')
      expect(payload.to_json).not_to include('vtoken_secret')
      expect(payload.to_json).not_to include('encrypted-secret')
    end
  end

  describe Captain::Tools::Copilot::DisconnectKaspiPayService do
    it 'disables Kaspi Pay without deleting account payment history' do
      payment = create(:kaspi_pay_payment, account: account, integration_hook: hook, source: conversation)
      service = described_class.new(assistant, user: admin)

      payload = JSON.parse(service.execute)

      expect(payload).to include('connected' => false, 'hook_id' => hook.id)
      expect(hook.reload).to be_disabled
      expect(hook.access_token).to be_blank
      expect(account.kaspi_pay_payments.find(payment.id)).to eq(payment)
    end
  end

  describe 'assistant-only admin guards' do
    let(:payment) { create(:kaspi_pay_payment, account: account, integration_hook: hook, source: conversation) }

    it 'blocks non-admin users from account-wide Kaspi Pay tools' do
      guarded_calls = [
        -> { Captain::Tools::Copilot::GetKaspiPayIntegrationStatusService.new(assistant, user: agent).execute },
        -> { Captain::Tools::Copilot::StartKaspiPayConnectionService.new(assistant, user: agent).execute },
        lambda do
          Captain::Tools::Copilot::SendKaspiPayPhoneService
            .new(assistant, user: agent)
            .execute(process_id: 'pid-1', phone_number: '77001234567')
        end,
        -> { Captain::Tools::Copilot::VerifyKaspiPayOtpService.new(assistant, user: agent).execute(process_id: 'pid-1', otp: '123456') },
        -> { Captain::Tools::Copilot::DisconnectKaspiPayService.new(assistant, user: agent).execute },
        -> { Captain::Tools::Copilot::SearchKaspiPayPaymentsService.new(assistant, user: agent).execute },
        -> { Captain::Tools::Copilot::GetKaspiPayPaymentService.new(assistant, user: agent).execute(payment_id: payment.id) },
        -> { Captain::Tools::Copilot::SyncKaspiPayPaymentStatusService.new(assistant, user: agent).execute(payment_id: payment.id) }
      ]

      guarded_calls.each do |call|
        expect { call.call }.to raise_error(ArgumentError, /administrator/)
      end
    end
  end

  describe Captain::ToolExecutionAuditService do
    it 'redacts Kaspi OTP, process, token, and secret values from audit payloads' do
      account.enable_features!('audit_logs')
      audit_payload = nil
      allow(Enterprise::AuditLog).to receive(:create) do |attributes|
        audit_payload = attributes[:audited_changes]
      end

      described_class.record(
        assistant: assistant,
        scope_name: Captain::ToolAccess::SCOPE_ASSISTANT,
        tool_definition: { id: 'verify_kaspi_pay_otp', title: 'Verify Kaspi Pay OTP' },
        arguments: { process_id: 'process-secret', otp: '123456', phone_number: '77001234567' },
        result: {
          processId: 'process-secret',
          tokenSN: 'token-secret',
          nested: { vtoken_secret: 'vtoken-secret' },
          public_value: 'visible'
        }
      )

      expect(audit_payload[:arguments]).to include('process_id' => '[FILTERED]', 'otp' => '[FILTERED]', 'phone_number' => '77001234567')
      expect(audit_payload[:result_preview]).not_to include('process-secret')
      expect(audit_payload[:result_preview]).not_to include('token-secret')
      expect(audit_payload[:result_preview]).not_to include('vtoken-secret')
      expect(audit_payload[:result_preview]).to include('visible')
    end
  end
end
