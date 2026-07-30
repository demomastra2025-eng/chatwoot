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
    allow_any_instance_of(Captain::Copilot::ToolConfirmationGate).to receive(:call).and_return(nil)
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
      expect(payload['delivery']).to include('mode' => 'link', 'sent' => true, 'deduplicated' => false)
      delivery_message = conversation.messages.find(payload.dig('delivery', 'message_id'))
      expect(delivery_message.content).to include('https://pay.kaspi.kz/pay/agent-token')
      expect(KaspiPay::StatusPollJob).to have_received(:perform_later).with(payload.dig('payment', 'id'))
    end

    it 'sends a native QR image and deduplicates a retry from the same incoming message' do
      create(:message, account: account, inbox: conversation.inbox, conversation: conversation, message_type: 'incoming', content: 'Пришлите QR')
      allow(client).to receive(:create_qr).once.and_return(
        'StatusCode' => 0,
        'Data' => {
          'QrOperationId' => 'agent-qr-image-1',
          'QrToken' => 'https://pay.kaspi.kz/pay/agent-image-token',
          'QrOriginalToken' => 'https://qr.kaspi.kz/agent-image-token',
          'ExpireDate' => 10.minutes.from_now.iso8601,
          'Amount' => 12_000
        }
      )
      allow(client).to receive(:render_qr_png)
        .with('https://qr.kaspi.kz/agent-image-token')
        .and_return("\x89PNG\r\n\x1A\nqr-image".b)
      tool = described_class.new(assistant)
      tool_context = Struct.new(:state).new({ conversation: { id: conversation.id } })

      first = JSON.parse(tool.perform(tool_context, amount: 12_000, delivery_mode: 'qr_image'))
      second = JSON.parse(tool.perform(tool_context, amount: 12_000, delivery_mode: 'qr_image'))

      expect(first.dig('delivery', 'attachment_ids').one?).to be(true)
      expect(second.dig('payment', 'id')).to eq(first.dig('payment', 'id'))
      expect(second.dig('delivery', 'message_id')).to eq(first.dig('delivery', 'message_id'))
      expect(second.dig('delivery', 'deduplicated')).to be(true)
      expect(client).to have_received(:create_qr).once
      expect(conversation.messages.outgoing.where(id: first.dig('delivery', 'message_id')).count).to eq(1)
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

    it 'uses the Copilot request as the retry boundary for separate legitimate payments' do
      allow(client).to receive(:create_qr).and_return(
        { 'StatusCode' => 0, 'Data' => { 'QrOperationId' => 'assistant-qr-request-1', 'QrToken' => 'https://pay.kaspi.kz/pay/request-1' } },
        { 'StatusCode' => 0, 'Data' => { 'QrOperationId' => 'assistant-qr-request-2', 'QrToken' => 'https://pay.kaspi.kz/pay/request-2' } }
      )
      service = described_class.new(assistant, user: admin, conversation: conversation)

      first = Llm::EventBus.with_context(request_id: 'copilot-request-1') do
        JSON.parse(service.execute(conversation_id: conversation.display_id, amount: 20_000))
      end
      account.kaspi_pay_payments.find(first.dig('payment', 'id')).update!(status: 'paid')
      second = Llm::EventBus.with_context(request_id: 'copilot-request-2') do
        JSON.parse(service.execute(conversation_id: conversation.display_id, amount: 20_000))
      end

      expect(second.dig('payment', 'id')).not_to eq(first.dig('payment', 'id'))
      expect(client).to have_received(:create_qr).twice
    end

    it 'creates an assistant-scope remote invoice when payment_type is invoice' do
      allow(client).to receive(:create_invoice).and_return(
        'StatusCode' => 0,
        'Data' => {
          'Id' => 'assistant-invoice-1',
          'OrderNumber' => 'order-1',
          'Amount' => 20_000,
          'Status' => 'RemotePaymentCreated'
        }
      )
      service = described_class.new(assistant, user: admin, conversation: conversation)

      payload = JSON.parse(
        service.execute(
          conversation_id: conversation.display_id,
          amount: 20_000,
          payment_type: 'invoice',
          phone_number: '77011234567',
          comment: 'Order 1'
        )
      )

      expect(payload['action']).to eq('create_kaspi_pay_payment')
      expect(payload.dig('payment', 'payment_type')).to eq('invoice')
      expect(payload.dig('payment', 'kaspi_operation_id')).to eq('assistant-invoice-1')
      expect(payload.dig('payment', 'kaspi_order_number')).to eq('order-1')
      expect(client).to have_received(:create_invoice).with(phone_number: '77011234567', amount: 20_000, comment: 'Order 1')
    end

    it 'rejects an invalid assistant payment_type before calling Kaspi' do
      service = described_class.new(assistant, user: admin, conversation: conversation)
      allow(client).to receive(:create_qr)
      allow(client).to receive(:create_invoice)

      expect do
        service.execute(conversation_id: conversation.display_id, amount: 20_000, payment_type: 'wire')
      end.to raise_error(ArgumentError, /payment_type/)
      expect(client).not_to have_received(:create_qr)
      expect(client).not_to have_received(:create_invoice)
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
    it 'returns safe integration metadata and verified provider session state for an administrator' do
      allow(client).to receive(:refresh).with(hook: hook).and_return(
        'success' => true,
        'tokenSN' => 'refreshed-token',
        'vtokenSecret' => 'refreshed-secret',
        'profileId' => 'profile-1',
        'organizationId' => 'org-1'
      )
      service = described_class.new(assistant, user: admin)

      payload = JSON.parse(service.execute(live_check: true))

      expect(payload['connected']).to be(true)
      expect(payload['local_status']).to eq('enabled')
      expect(payload['provider_session']).to include('checked' => true, 'healthy' => true, 'status' => 'active')
      expect(payload.dig('hook', 'metadata')).to include('organization_id' => 'org-1', 'org_name' => 'Test Merchant')
      expect(payload.to_json).not_to include('vtoken_secret')
      expect(payload.to_json).not_to include('encrypted-secret')
      expect(payload.to_json).not_to include('refreshed-secret')
    end

    it 'defaults to local-only status without making a provider request' do
      allow(client).to receive(:refresh)
      service = described_class.new(assistant, user: admin)

      payload = JSON.parse(service.execute)

      expect(payload['provider_session']).to include('checked' => false, 'status' => 'not_checked')
      expect(client).not_to have_received(:refresh)
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

  describe Captain::Tools::Copilot::RefundKaspiPayPaymentService do
    it 'requests a refund for an account payment without exposing Kaspi secrets' do
      payment = create(:kaspi_pay_payment, account: account, integration_hook: hook, source: conversation, amount: 15_000, status: 'paid',
                                           kaspi_operation_id: '15530881826')
      allow(client).to receive(:create_refund).with(qr_operation_id: '15530881826', return_amount: 5_000).and_return(
        'StatusCode' => 0,
        'Data' => { 'Status' => 'Returned' }
      )
      service = described_class.new(assistant, user: admin)

      payload = JSON.parse(service.execute(payment_id: payment.id, amount: 5_000))

      expect(payload['action']).to eq('refund_kaspi_pay_payment')
      expect(payload.dig('payment', 'id')).to eq(payment.id)
      expect(payload.dig('payment', 'refunded_amount')).to eq(5_000)
      expect(payload.dig('payment', 'remaining_refundable_amount')).to eq(10_000)
      expect(payload.dig('payment', 'partially_refunded')).to be(true)
      expect(payload.to_json).not_to include('vtoken_secret')
    end
  end

  describe Captain::Tools::Copilot::CancelKaspiPayInvoiceService do
    it 'cancels an account-scoped pending invoice' do
      payment = create(:kaspi_pay_payment, account: account, integration_hook: hook, source: conversation, payment_type: 'invoice',
                                           kaspi_operation_id: 'invoice-1')
      allow(client).to receive(:cancel_invoice).with('invoice-1').and_return(
        'StatusCode' => 0,
        'Data' => { 'Status' => 'Cancelled' }
      )

      payload = JSON.parse(described_class.new(assistant, user: admin).execute(payment_id: payment.id))

      expect(payload['action']).to eq('cancel_kaspi_pay_invoice')
      expect(payload.dig('payment', 'status')).to eq('cancelled')
      expect(payment.reload.status).to eq('cancelled')
    end
  end

  describe Captain::Tools::Copilot::GetKaspiPayProviderHistoryService do
    it 'returns one normalized provider operations history page' do
      allow(client).to receive(:operations_history).with(
        end_date: '2026-07-30', last_transaction_date: nil, statement_period_code: 0
      ).and_return('StatusCode' => 0, 'Data' => { 'Operations' => [{ 'Id' => 101 }] })

      payload = JSON.parse(described_class.new(assistant, user: admin).execute(kind: 'operations', end_date: '2026-07-30'))

      expect(payload).to include('action' => 'get_kaspi_pay_provider_history', 'kind' => 'operations')
      expect(payload.dig('data', 'Operations')).to eq([{ 'Id' => 101 }])
    end
  end

  describe Captain::Tools::Copilot::GetKaspiPayClientInfoService do
    it 'returns masked phone and provider client status without exposing the raw phone' do
      allow(client).to receive(:client_info).with('77011234567').and_return(
        'StatusCode' => 0,
        'Data' => { 'ClientName' => 'Test Client', 'ClientStatus' => 'Active' }
      )

      payload = JSON.parse(described_class.new(assistant, user: admin).execute(phone_number: '+7 (701) 123-45-67'))

      expect(payload).to include(
        'action' => 'get_kaspi_pay_client_info',
        'found' => true,
        'phone_number' => '77*****4567',
        'client_name' => 'Test Client',
        'client_status' => 'Active'
      )
      expect(payload.to_json).not_to include('77011234567')
    end
  end

  describe Captain::Tools::Copilot::ReconcileKaspiPayPaymentService do
    it 'marks the payment refunded when provider operation details include returns' do
      payment = create(:kaspi_pay_payment, account: account, integration_hook: hook, source: conversation, amount: 15_000, status: 'paid',
                                           kaspi_operation_id: '15530881826')
      allow(client).to receive(:operation_details).with('15530881826', operation_method: 0).and_return(
        'StatusCode' => 0,
        'Data' => { 'Returns' => [{ 'Amount' => 15_000 }] }
      )
      service = described_class.new(assistant, user: admin)

      payload = JSON.parse(service.execute(payment_id: payment.id))

      expect(payload['action']).to eq('reconcile_kaspi_pay_payment')
      expect(payload.dig('payment', 'status')).to eq('refunded')
      expect(payment.reload.status).to eq('refunded')
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
        -> { Captain::Tools::Copilot::SyncKaspiPayPaymentStatusService.new(assistant, user: agent).execute(payment_id: payment.id) },
        -> { Captain::Tools::Copilot::RefundKaspiPayPaymentService.new(assistant, user: agent).execute(payment_id: payment.id, amount: 100) },
        -> { Captain::Tools::Copilot::CancelKaspiPayInvoiceService.new(assistant, user: agent).execute(payment_id: payment.id) },
        -> { Captain::Tools::Copilot::GetKaspiPayProviderHistoryService.new(assistant, user: agent).execute(kind: 'invoices') },
        -> { Captain::Tools::Copilot::GetKaspiPayClientInfoService.new(assistant, user: agent).execute(phone_number: '77011234567') },
        -> { Captain::Tools::Copilot::ReconcileKaspiPayPaymentService.new(assistant, user: agent).execute(payment_id: payment.id) }
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
