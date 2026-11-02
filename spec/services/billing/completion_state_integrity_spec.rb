# frozen_string_literal: true

require 'rails_helper'

# Regressions R1-R8; original reviewer RED proof remains outside this repository.
# rubocop:disable RSpec/AnyInstance
RSpec.describe Billing::CompletionState do
  self.use_transactional_tests = false
  let(:account) { create(:account) }
  let(:day) { Billing.today_almaty + 4.days }
  let!(:profile) do
    Billing::AccountProfile.create!(account: account, billing_enabled: true, paid_until: day,
                                    custom_monthly_price_minor: 10_000, legal_name: 'Synthetic payer',
                                    billing_tax_id: '210540012345', contract_number: 'REVIEW-CONTRACT')
  end

  before do
    WebMock.disable_net_connect!
    allow(Billing::Config).to receive_messages(autobilling_enabled?: true, bcc_open_api_configured?: false,
                                               bcc_ecom_configured?: false, closing_documents_configured?: false,
                                               bcc_supplier_bin: '980123456789', bcc_business_iban: 'KZ000000000000000000',
                                               bcc_supplier_name: 'Synthetic supplier')
    allow(Billing::InvoicePdfGenerator).to receive(:new).and_return(instance_double(Billing::InvoicePdfGenerator, render: '%PDF review'))
    allow(ActiveStorage::Blob).to receive(:create_and_upload!).and_wrap_original do |original, **arguments|
      assert_committed_io
      original.call(**arguments)
    end
  end

  def assert_committed_io
    expect(ActiveRecord::Base.connection.open_transactions).to eq(0)
  end

  def checkpoint(record, name)
    record.reload.metadata.dig('completion_v1', 'steps', name)
  end

  def observation(name, values)
    puts "REVIEW_OBSERVATION #{name}: #{values.to_json}"
  end

  def generate(notify: false)
    Billing::InvoiceGeneratorService.new(account: account, period_start: day, notify: notify).perform
  end

  def conversation!
    conversation = create(:conversation, account: account, inbox: create(:inbox, account: account))
    profile.update!(billing_whatsapp_conversation_id: conversation.id)
    conversation
  end

  def settle(invoice, ref: 'review-ref', amount: invoice.amount_minor)
    Billing::PaymentMatcher.new(source: 'manual', payload: {
                                  bank_reference_id: ref, invoice_number: invoice.invoice_number, amount_minor: amount, currency: invoice.currency
                                }).perform
  end

  def change_checkpoint(invoice)
    metadata = invoice.reload.metadata.deep_dup
    yield metadata.fetch('completion_v1')
    invoice.update!(metadata: metadata)
  end

  def enable_ecom
    allow(Billing::Config).to receive_messages(bcc_ecom_configured?: true, bcc_ecom_base_url: 'https://ecom.review.test',
                                               bcc_ecom_merchant_id: 'synthetic-merchant', bcc_ecom_terminal_id: 'synthetic-terminal',
                                               bcc_ecom_secret_key: 'synthetic-secret')
    profile.update!(autopay_enabled: true, bcc_card_token: 'synthetic-card')
  end

  def parallel(count = 2)
    ready = Queue.new
    start = Queue.new
    threads = Array.new(count) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          connection.execute("SET statement_timeout='8s'")
          ready << connection.select_value('SELECT pg_backend_pid()')
          start.pop
          yield
        ensure
          connection.execute("SET statement_timeout='14s'")
        end
      end
    end
    pids = Array.new(count) { ready.pop }
    expect(pids.uniq.length).to eq(count)
    count.times { start << true }
    threads.map(&:value)
  end

  it '01 keeps missing-target dunning false with no stage progress' do
    invoice = generate
    invoice.update!(due_on: Billing.today_almaty)
    result = Billing::NotificationService.new(invoice: invoice).deliver_dunning_reminder!(stage: 't_zero')
    Billing::DunningJob.perform_now
    expect([result, invoice.reload.last_reminder_stage, Message.count]).to eq([false, nil, 0])
  end

  it '02 refuses legacy and structurally malformed permission without Message or HTTP' do
    conversation!
    invoice = generate
    [{ 'notified' => true, 'notifications' => [{ 'event' => 'invoice_issued' }] },
     { 'completion_v1' => { 'managed' => true, 'context' => [], 'steps' => [] } }].each do |metadata|
      invoice.update!(metadata: metadata)
      result = Billing::NotificationService.new(invoice: invoice).deliver_recurring_fallback!
      expect(result).to be(false)
    end
    expect(Message.count).to eq(0)
    expect(WebMock::RequestRegistry.instance.requested_signatures.hash.size).to eq(0)
  end

  it '03 holds a deleted irreversible checkpoint rather than manufacturing POST permission' do
    conversation!
    invoice = generate
    change_checkpoint(invoice) { |value| value.fetch('steps').delete('bcc_invoice') }
    allow(Billing::Config).to receive(:bcc_open_api_configured?).and_return(true)
    client = instance_double(Billing::BccOpenApiClient)
    allow(Billing::BccOpenApiClient).to receive(:new).and_return(client)
    calls = 0
    allow(client).to receive(:register_invoice) {
      calls += 1
      { external_invoice_id: 'synthetic-unsafe-post' }
    }
    Billing::InvoiceGeneratorService.resume!(invoice)
    observation('missing_checkpoint', calls: calls, step: checkpoint(invoice, 'bcc_invoice'))
    expect(calls).to eq(0)
    expect(checkpoint(invoice, 'bcc_invoice')['state']).to eq('needs_review')
  end

  it '04 rejects context changed after its input_digest was committed' do
    conversation!
    invoice = generate
    change_checkpoint(invoice) { |value| value.fetch('context').fetch('document')['supplier_bin'] = '111111111111' }
    allow(Billing::Config).to receive(:bcc_open_api_configured?).and_return(true)
    client = instance_double(Billing::BccOpenApiClient)
    allow(Billing::BccOpenApiClient).to receive(:new).and_return(client)
    calls = 0
    allow(client).to receive(:register_invoice) {
      calls += 1
      { external_invoice_id: 'synthetic-changed-input' }
    }
    Billing::InvoiceGeneratorService.resume!(invoice)
    observation('changed_context', calls: calls, state: checkpoint(invoice, 'bcc_invoice')['state'])
    expect(calls).to eq(0)
  end

  it '05 puts a deleted completed Message receipt on hold without resending or advancing dunning' do
    conv = conversation!
    invoice = generate
    service = Billing::NotificationService.new(invoice: invoice)
    expect(service.deliver_dunning_reminder!(stage: 't_zero')).to be(true)
    message_id = checkpoint(invoice, 'dunning_t_zero').dig('receipt', 'message_id')
    Message.where(id: message_id).delete_all
    result = service.deliver_dunning_reminder!(stage: 't_zero')
    observation('deleted_message', result: result, state: checkpoint(invoice, 'dunning_t_zero')['state'], messages: conv.messages.count)
    expect([result, checkpoint(invoice, 'dunning_t_zero')['state'], conv.messages.count]).to eq([false, 'needs_review', 0])
  end

  it '06 settles saved approval after card/autopay revocation without requiring new charge permission' do
    invoice = generate
    invoice.update!(due_on: Billing.today_almaty)
    enable_ecom
    state = described_class.new(invoice)
    token = state.claim!('recurring_charge_1', configured: true)
    state.finish!('recurring_charge_1', token, receipt: { 'approved' => true, 'bank_reference_id' => 'synthetic-approval',
                                                          'raw_payload' => { 'status' => 'approved' } })
    invoice.update!(recurring_attempts_count: 1, last_recurring_attempt_at: Time.current)
    profile.update!(autopay_enabled: false, bcc_card_token: nil)
    Billing::BccRecurringChargeJob.perform_now
    Billing::GenerateUpcomingInvoicesJob.perform_now
    observation('saved_approval_revoked', status: invoice.reload.status, events: Billing::PaymentEvent.count,
                                          finance: OwnerFinance::TransactionRecord.count, count: invoice.recurring_attempts_count)
    expect([invoice.status, Billing::PaymentEvent.count, OwnerFinance::TransactionRecord.count]).to eq(['paid', 1, 1])
    expect(WebMock::RequestRegistry.instance.requested_signatures.hash.size).to eq(0)
  end

  it '07 never interprets HTTP200 unknown body as a decline permitting the next charge' do
    invoice = generate
    invoice.update!(due_on: Billing.today_almaty)
    enable_ecom
    request = stub_request(:post, 'https://ecom.review.test/recurring/charge').with do
      expect(ActiveRecord::Base.connection.open_transactions).to eq(0)
      true
    end.to_return(status: 200, body: { message: 'outcome unknown' }.to_json)
    Billing::BccRecurringChargeJob.perform_now
    first_state = checkpoint(invoice, 'recurring_charge_1')['state']
    travel 25.hours do
      Billing::BccRecurringChargeJob.perform_now
    end
    observation('unknown_ecom', first_state: first_state, attempts: invoice.reload.recurring_attempts_count,
                                step1: checkpoint(invoice, 'recurring_charge_1'), step2: checkpoint(invoice, 'recurring_charge_2'))
    expect([first_state, invoice.recurring_attempts_count]).to eq(['needs_review', 1])
    expect(request).to have_been_requested.once
  end

  it '08 rechecks explicit requested historical period at the automatic creation boundary' do
    service = Billing::InvoiceGeneratorService.new(account: account, period_start: Billing.today_almaty - 1.year, notify: false)
    result = service.perform(automatic_through: Billing.today_almaty + 5.days)
    observation('automatic_requested_history', result: result&.period_start, invoice_count: Billing::Invoice.count)
    expect(result).to be_nil
    expect(Billing::Invoice.count).to eq(0)
  end

  it '09 rejects Event immutable invoice reference mismatch before Message materialization' do
    conv = conversation!
    invoice = generate
    allow(Billing::ClosingDocumentsJob).to receive(:perform_later).and_raise('synthetic after-settlement fault')
    expect { settle(invoice) }.to raise_error('synthetic after-settlement fault')
    event = Billing::PaymentEvent.last
    change_checkpoint(event) { |value| value.fetch('context')['invoice_id'] = invoice.id + 99_999 }
    result = Billing::NotificationService.new(invoice: invoice, payment_event: event).deliver_payment_confirmation!
    observation('event_reference_mismatch', result: result, messages: conv.messages.count)
    expect([result, conv.messages.count]).to eq([false, 0])
  end

  it '10 preserves PDF and closing snapshot after mutable Profile and Config changes' do
    conversation!
    invoice = generate
    allow(Billing::InvoicePdfGenerator).to receive(:new).and_call_original
    original_pdf = Billing::InvoicePdfGenerator.new(invoice: invoice).render
    profile.update!(legal_name: 'Changed payer', contract_number: 'CHANGED-CONTRACT', billing_tax_id: '111111111111')
    allow(Billing::Config).to receive_messages(bcc_supplier_name: 'Changed supplier', bcc_supplier_bin: '111111111111')
    expect(Billing::InvoicePdfGenerator.new(invoice: invoice.reload).render).to eq(original_pdf)
    invoice.update!(status: 'paid')
    allow(Billing::Config).to receive(:closing_documents_configured?).and_return(true)
    sigex = instance_double(Billing::SigexClient, sign_payload!: { cms_signature: 'synthetic' })
    edo = instance_double(Billing::UchetEdoClient)
    payloads = []
    allow(edo).to receive(:send_eavr!) do |eavr_payload:, **|
      expect(ActiveRecord::Base.connection.open_transactions).to eq(0)
      payloads << eavr_payload
      { document_id: 'synthetic-review-eavr' }
    end
    service = Billing::ClosingDocumentsService.new(invoice: invoice, sigex_client: sigex, edo_client: edo)
    2.times { service.send_eavr! }
    expect(payloads).to match([hash_including(contract_number: 'REVIEW-CONTRACT', supplier_name: 'Synthetic supplier',
                                              supplier_bin: '980123456789', customer_name: 'Synthetic payer', customer_bin: '210540012345')])
  end

  it '11 rolls back Message and failed marker together then safely replays once' do
    conv = conversation!
    invoice = generate
    allow_any_instance_of(described_class).to receive(:write!).and_wrap_original do |original, name, state, **details|
      raise 'synthetic marker failure' if name == 'recurring_fallback' && state == 'completed'

      original.call(name, state, **details)
    end
    service = Billing::NotificationService.new(invoice: invoice)
    expect(service.deliver_recurring_fallback!).to be(false)
    expect(conv.messages.count).to eq(0)
    allow_any_instance_of(described_class).to receive(:write!).and_call_original
    2.times { expect(service.deliver_recurring_fallback!).to be(true) }
    expect(conv.messages.count).to eq(1)
  end

  it '12 rejects stale irreversible claim and late receipt without duplicate external operation' do
    invoice = generate
    state = described_class.new(invoice)
    token = state.claim!('bcc_invoice', configured: true)
    travel 6.minutes do
      expect(state.claim!('bcc_invoice', configured: true)).to be_nil
    end
    expect(state.finish!('bcc_invoice', token, receipt: { 'provider_id' => 'late' }, attributes: { bcc_external_invoice_id: 'late' })).to be(false)
    expect([checkpoint(invoice, 'bcc_invoice')['state'], invoice.reload.bcc_external_invoice_id]).to eq(['needs_review', nil])
  end

  it '13 serializes actual PG duplicate generation and settlement with stable financial counters' do
    conv = conversation!
    ids = parallel { generate.id }
    expect(ids.uniq.length).to eq(1)
    invoice = Billing::Invoice.find(ids.first)
    events = parallel { settle(Billing::Invoice.find(invoice.id)).id }
    paid_until = profile.reload.paid_until
    2.times { settle(invoice) }
    expect(events.uniq.length).to eq(1)
    expect([Billing::Invoice.count, Billing::PaymentEvent.count, OwnerFinance::TransactionRecord.count, conv.messages.count]).to eq([1, 1, 1, 1])
    expect(profile.reload.paid_until).to eq(paid_until)
    expect(ActiveStorage::Attachment.where(record: invoice, name: 'pdf_file').count).to eq(1)
  end

  it '14 refuses another charge when previous completed recurring step has lost its receipt' do
    invoice = generate
    invoice.update!(due_on: Billing.today_almaty)
    enable_ecom
    state = described_class.new(invoice)
    token = state.claim!('recurring_charge_1', configured: true)
    state.finish!('recurring_charge_1', token, receipt: { 'approved' => true, 'bank_reference_id' => 'synthetic-approval' })
    invoice.update!(recurring_attempts_count: 1, last_recurring_attempt_at: 25.hours.ago)
    change_checkpoint(invoice) { |value| value.fetch('steps').fetch('recurring_charge_1')['receipt'] = nil }
    request = stub_request(:post, 'https://ecom.review.test/recurring/charge')
              .to_return(status: 200, body: { approved: true, bank_reference_id: 'synthetic-second-charge' }.to_json)
    Billing::BccRecurringChargeJob.perform_now
    observation('missing_charge_receipt', attempts: invoice.reload.recurring_attempts_count,
                                          previous: checkpoint(invoice, 'recurring_charge_1'), next_step: checkpoint(invoice, 'recurring_charge_2'))
    expect(invoice.recurring_attempts_count).to eq(1)
    expect(request).not_to have_been_requested
  end

  # The barriers must show the real PG wait before both lifecycle/Task threads finish.
  # rubocop:disable RSpec/ExampleLength
  it 'serializes actual User reactivation before Account and Task FK materialization without retrying deadlocks' do
    invoice = generate
    owner = create(:user, id: 6)
    workspace = create(:account, id: 48)
    create(:account_user, account: workspace, user: owner, role: :administrator)
    allow_any_instance_of(Billing::PaymentMatcher).to receive(:dispatch_completion!).and_raise('post settlement')
    expect { settle(invoice, amount: 20_000) }.to raise_error('post settlement')
    event = Billing::PaymentEvent.last
    allow_any_instance_of(Billing::PaymentMatcher).to receive(:dispatch_completion!).and_call_original
    Crm::TaskCatalogs::Provisioner.new(account: workspace).perform
    ready = Queue.new
    release = Queue.new
    reactivation_pid = Queue.new
    allow(Crm::Task).to receive(:create!).and_wrap_original do |original, *args, **kwargs|
      if Thread.current[:billing_task]
        ready << ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()')
        release.pop
      end
      original.call(*args, **kwargs)
    end
    reactivator = Captain::Tools::Account::ReactivateUserService.allocate
    allow(reactivator).to receive(:account).and_return(account)
    reactivator.instance_variable_set(:@user, owner)
    finance = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        connection.execute("SET statement_timeout='8s'")
        Thread.current[:billing_task] = true
        Billing::PaymentMatcher.resume!(Billing::PaymentEvent.find(event.id))
      ensure
        connection.execute("SET statement_timeout='14s'")
      end
    end
    finance_pid = Timeout.timeout(15) { ready.pop }
    lifecycle = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        connection.execute("SET statement_timeout='8s'")
        reactivation_pid << connection.select_value('SELECT pg_backend_pid()')
        reactivator.send(:reactivate_user, User.find(owner.id), snapshot_id: nil, role: nil, availability: nil)
      ensure
        connection.execute("SET statement_timeout='14s'")
      end
    end
    lifecycle_pid = Timeout.timeout(5) { reactivation_pid.pop }
    expect(lifecycle_pid).not_to eq(finance_pid)
    Timeout.timeout(5) do
      loop do
        blockers = ActiveRecord::Base.connection.select_value("SELECT pg_blocking_pids(#{lifecycle_pid.to_i})::text")
        break if blockers.include?(finance_pid.to_s)

        sleep 0.01
      end
    end
    release << true
    expect(finance.value.status).to eq('matched')
    expect(lifecycle.value[:action]).to eq('reactivate_user')
    expect(Crm::Task.count).to eq(1)
    expect(checkpoint(event, 'review_task').dig('receipt', 'task_id')).to eq(Crm::Task.last.id)
    expect(AccountUser.exists?(account_id: account.id, user_id: owner.id)).to be(true)
  ensure
    release << true if release
    finance&.join(10)
    lifecycle&.join(10)
  end

  # rubocop:enable RSpec/ExampleLength

  [nil, [], {}, { 'approved' => 'true', 'bank_reference_id' => 'typed-fault', 'raw_payload' => { 'approved' => true } },
   { 'approved' => false, 'status' => 'declined', 'raw_payload' => { 'message' => 'unknown' } }].each do |receipt|
    it "holds a completed recurring receipt with invalid typed evidence #{receipt.inspect}" do
      invoice = generate
      invoice.update!(due_on: Billing.today_almaty)
      enable_ecom
      state = described_class.new(invoice)
      token = state.claim!('recurring_charge_1', configured: true)
      state.finish!('recurring_charge_1', token,
                    receipt: { 'approved' => true, 'bank_reference_id' => 'saved', 'raw_payload' => { 'approved' => true } })
      invoice.update!(recurring_attempts_count: 1, last_recurring_attempt_at: 25.hours.ago)
      change_checkpoint(invoice) { |value| value['steps']['recurring_charge_1']['receipt'] = receipt }
      2.times { Billing::BccRecurringChargeJob.perform_now }
      expect([invoice.reload.recurring_attempts_count, checkpoint(invoice, 'recurring_charge_1')['state']]).to eq([1, 'needs_review'])
      expect(WebMock::RequestRegistry.instance.requested_signatures.hash).to be_empty
    end
  end

  %w[missing unknown_state operation_key input_digest].each do |fault|
    it "never lifts notify false after #{fault} checkpoint corruption" do
      conversation!
      invoice = generate
      change_checkpoint(invoice) do |value|
        step = value['steps']['invoice_issued']
        case fault
        when 'missing' then value['steps'].delete('invoice_issued')
        when 'unknown_state' then step['state'] = 'unexpected'
        else step[fault] = 'corrupted'
        end
      end
      2.times { Billing::InvoiceGeneratorService.resume!(invoice) }
      expect(Message.count).to eq(0)
      expect(checkpoint(invoice, 'invoice_issued')['state']).to eq('needs_review')
    end
  end

  it 'recovers an already approved charge after all new-debit gates are revoked' do
    invoice = generate
    invoice.update!(due_on: Billing.today_almaty)
    enable_ecom
    state = described_class.new(invoice)
    token = state.claim!('recurring_charge_1', configured: true)
    state.finish!('recurring_charge_1', token, receipt: { 'approved' => true, 'bank_reference_id' => 'saved-without-config',
                                                          'raw_payload' => { 'approved' => true } })
    invoice.update!(recurring_attempts_count: 1)
    profile.update!(billing_enabled: false, autopay_enabled: false, bcc_card_token: nil, custom_monthly_price_minor: 900_000)
    allow(Billing::Config).to receive_messages(autobilling_enabled?: false, bcc_ecom_configured?: false)
    2.times do
      Billing::GenerateUpcomingInvoicesJob.perform_now
      Billing::BccRecurringChargeJob.perform_now
    end
    expect([invoice.reload.status, invoice.amount_minor, invoice.recurring_attempts_count]).to eq(['paid', 10_000, 1])
    expect([Billing::PaymentEvent.count, OwnerFinance::TransactionRecord.count]).to eq([1, 1])
    expect(profile.reload.paid_until).to eq(invoice.period_end)
    expect(WebMock::RequestRegistry.instance.requested_signatures.hash).to be_empty
  end

  it 'rejects an automatic future period beyond the requested window while preserving manual generation' do
    requested = Billing.today_almaty + 6.days
    expect(Billing::InvoiceGeneratorService.new(account: account, period_start: requested, notify: false)
      .perform(automatic_through: Billing.today_almaty + 5.days)).to be_nil
    expect(Billing::InvoiceGeneratorService.new(account: account, period_start: requested, notify: false).perform.period_start).to eq(requested)
  end

  it 'keeps canonical digests stable across jsonb object key order and holds unprovable legacy hashes' do
    invoice = generate
    state = described_class.new(invoice)
    context = state.context
    expect(described_class.digest(context.to_a.reverse.to_h)).to eq(state.metadata['input_digest'])
    change_checkpoint(invoice) { |value| value.delete('format') }
    expect(state.claim!('bcc_invoice', configured: true)).to be_nil
    expect(checkpoint(invoice, 'bcc_invoice')['state']).to eq('needs_review')
  end

  it 'isolates malformed managed steps from recovery of another invoice' do
    bad = generate
    change_checkpoint(bad) { |value| value['steps'] = [] }
    other = create(:account)
    Billing::AccountProfile.create!(account: other, billing_enabled: true, paid_until: day, custom_monthly_price_minor: 10_000)
    good = Billing::InvoiceGeneratorService.new(account: other, notify: false).perform
    Billing::GenerateUpcomingInvoicesJob.perform_now
    expect(good.reload.pdf_file).to be_attached
    expect(checkpoint(bad, 'pdf')['state']).to eq('needs_review')
  end

  it 'holds deleted and foreign completed Task receipts without recreating tasks' do
    invoice = generate
    owner = create(:user, id: 6)
    workspace = create(:account, id: 48)
    create(:account_user, account: workspace, user: owner, role: :administrator)
    event = settle(invoice, amount: 20_000)
    task = Crm::Task.last
    task.update!(idempotency_key: 'foreign-task')
    Billing::PaymentMatcher.resume!(event)
    expect(checkpoint(event, 'review_task')['state']).to eq('needs_review')
    expect(Crm::Task.count).to eq(1)
    Crm::Task.where(id: task.id).delete_all
    Billing::PaymentMatcher.resume!(event)
    expect(Crm::Task.count).to eq(0)
  end

  it 'holds a foreign Message row receipt without materializing another Message' do
    conv = conversation!
    invoice = generate
    service = Billing::NotificationService.new(invoice: invoice)
    expect(service.deliver_dunning_reminder!(stage: 't_zero')).to be(true)
    wrong = create(:conversation, account: account, inbox: create(:inbox, account: account))
    message_id = checkpoint(invoice, 'dunning_t_zero').dig('receipt', 'message_id')
    Message.where(id: message_id).update_all(conversation_id: wrong.id) # rubocop:disable Rails/SkipsModelValidations -- deliberate receipt fault
    expect(service.deliver_dunning_reminder!(stage: 't_zero')).to be(false)
    expect(checkpoint(invoice, 'dunning_t_zero')['state']).to eq('needs_review')
    expect(Message.count).to eq(1)
    expect(conv.messages.count).to eq(0)
  end

  it 'allows exactly the next debit after a real explicit decline, then settles a real approval once' do
    invoice = generate
    invoice.update!(due_on: Billing.today_almaty)
    enable_ecom
    request = stub_request(:post, 'https://ecom.review.test/recurring/charge')
              .to_return(status: 200, body: { status: 'declined', message: 'Synthetic explicit decline' }.to_json)
              .then.to_return(status: 200, body: { approved: true, bank_reference_id: 'synthetic-approved-next' }.to_json)
    Billing::BccRecurringChargeJob.perform_now
    expect([invoice.reload.status, invoice.recurring_attempts_count]).to eq(['issued', 1])
    expect(checkpoint(invoice, 'recurring_charge_1').dig('receipt', 'raw_payload', 'status')).to eq('declined')
    travel 25.hours do
      2.times { Billing::BccRecurringChargeJob.perform_now }
    end
    expect([invoice.reload.status, invoice.recurring_attempts_count, invoice.amount_minor]).to eq(['paid', 2, 10_000])
    expect([Billing::PaymentEvent.count, OwnerFinance::TransactionRecord.count]).to eq([1, 1])
    expect(profile.reload.paid_until).to eq(invoice.period_end)
    expect(request).to have_been_requested.twice
  end

  %w[pending blocked skipped unexpected].each do |status|
    it "holds a previous irreversible charge in unprovable state #{status}" do
      invoice = generate
      invoice.update!(due_on: Billing.today_almaty)
      enable_ecom
      state = described_class.new(invoice)
      token = state.claim!('recurring_charge_1', configured: true)
      state.finish!('recurring_charge_1', token,
                    receipt: { 'approved' => true, 'bank_reference_id' => 'saved', 'raw_payload' => { 'approved' => true } })
      invoice.update!(recurring_attempts_count: 1, last_recurring_attempt_at: 25.hours.ago)
      change_checkpoint(invoice) { |value| value['steps']['recurring_charge_1']['state'] = status }
      Billing::BccRecurringChargeJob.perform_now
      expect([invoice.reload.recurring_attempts_count, checkpoint(invoice, 'recurring_charge_1')['state']]).to eq([1, 'needs_review'])
      expect(WebMock::RequestRegistry.instance.requested_signatures.hash).to be_empty
    end
  end

  it 'checks the real Event to Invoice binding even when the corrupt context has a valid canonical digest' do
    conversation!
    invoice = generate
    allow(Billing::ClosingDocumentsJob).to receive(:perform_later).and_raise('post settlement')
    expect { settle(invoice) }.to raise_error('post settlement')
    event = Billing::PaymentEvent.last
    change_checkpoint(event) do |value|
      value['context']['invoice_id'] = invoice.id + 1
      value['input_digest'] = described_class.digest(value['context'])
      value['steps'].each_value { |item| item['input_digest'] = value['input_digest'] }
    end
    expect(Billing::NotificationService.new(invoice: invoice, payment_event: event).deliver_payment_confirmation!).to be(false)
    expect(Message.count).to eq(0)
    expect(checkpoint(event, 'payment_confirmed')['state']).to eq('needs_review')
  end
end
# rubocop:enable RSpec/AnyInstance
