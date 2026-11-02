# frozen_string_literal: true

require 'rails_helper'

# Faults must intercept fresh AR instances loaded by competing writers; each
# scenario checks its committed financial invariants together.
# rubocop:disable RSpec/AnyInstance, RSpec/MultipleExpectations
RSpec.describe Billing::CompletionState do
  self.use_transactional_tests = false

  let(:account) { create(:account) }
  let(:day) { Billing.today_almaty + 4.days }
  let!(:profile) do
    Billing::AccountProfile.create!(account: account, billing_enabled: true, paid_until: day, custom_monthly_price_minor: 10_000)
  end

  before do
    WebMock.disable_net_connect!
    allow(Billing::Config).to receive_messages(autobilling_enabled?: true, bcc_open_api_configured?: false, bcc_ecom_configured?: false)
    allow(Billing::InvoicePdfGenerator).to receive(:new).and_return(instance_double(Billing::InvoicePdfGenerator, render: '%PDF synthetic'))
    allow(ActiveStorage::Blob).to receive(:create_and_upload!).and_wrap_original do |original, **arguments|
      assert_no_open_transaction
      original.call(**arguments)
    end
    allow(Billing::Config).to receive_messages(bcc_supplier_bin: '980123456789', bcc_business_iban: 'KZ000000000000000000',
                                               bcc_supplier_name: 'Synthetic supplier')
  end

  def assert_no_open_transaction
    expect(ActiveRecord::Base.connection.open_transactions).to eq(0)
  end

  def step(record, name)
    record.reload.metadata.dig('completion_v1', 'steps', name)
  end

  def billing_conversation
    conversation = create(:conversation, account: account, inbox: create(:inbox, account: account))
    profile.update!(billing_whatsapp_conversation_id: conversation.id, billing_tax_id: '210540012345', legal_name: 'Synthetic payer',
                    contract_number: 'SYNTHETIC-1')
    conversation
  end

  def settle(invoice, ref: 'synthetic-ref', amount: invoice.amount_minor)
    Billing::PaymentMatcher.new(source: 'manual', payload: {
                                  bank_reference_id: ref, invoice_number: invoice.invoice_number, amount_minor: amount, currency: invoice.currency
                                }).perform
  end

  def parallel_writers(count = 2)
    ready = Queue.new
    start = Queue.new
    threads = Array.new(count) do |index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          connection.execute("SET statement_timeout = '8s'")
          ready << connection.select_value('SELECT pg_backend_pid()')
          start.pop
          yield(index)
        ensure
          connection.execute("SET statement_timeout = '14s'")
        end
      end
    end
    pids = Array.new(count) { ready.pop }
    expect(pids.uniq.size).to eq(count)
    count.times { start << true }
    threads.map(&:value)
  end

  def generate(notify: false)
    Billing::InvoiceGeneratorService.new(account: account, period_start: day, notify: notify).perform
  end

  it 'resumes PDF after a crash following invoice creation', :baseline_probe do
    renderer = instance_double(Billing::InvoicePdfGenerator)
    allow(renderer).to receive(:render).and_raise('synthetic PDF crash').once
    allow(Billing::InvoicePdfGenerator).to receive(:new).and_return(renderer)
    expect { generate }.to raise_error('synthetic PDF crash')
    invoice = Billing::Invoice.last
    original = invoice.attributes.slice('amount_minor', 'period_end', 'invoice_number')
    allow(renderer).to receive(:render).and_return('%PDF recovered')
    expect(generate.id).to eq(invoice.id)
    expect(invoice.reload.pdf_file).to be_attached
    expect(invoice.attributes.slice(*original.keys)).to eq(original)
  end

  it 'returns false when there is no billing conversation', :baseline_probe do
    invoice = generate(notify: true)
    expect(Billing::NotificationService.new(invoice: invoice).deliver_dunning_reminder!(stage: 't_zero')).to be(false)
  end

  it 'finds a missed T-5 day without creating multiple historical months', :baseline_probe do
    Billing::GenerateUpcomingInvoicesJob.perform_now
    expect(account.billing_invoices.count).to eq(1)
    expect(account.billing_invoices.first.period_start).to eq(day)
  end

  it 'retains notify:false through retries and materializes only one PDF attachment' do
    conversation = billing_conversation
    invoice = generate
    profile.update!(custom_monthly_price_minor: 900_000)
    Billing::InvoiceGeneratorService.new(account: account, period_start: day, notify: true).perform
    expect(invoice.reload.amount_minor).to eq(10_000)
    expect(step(invoice, 'invoice_issued')['state']).to eq('skipped')
    expect(conversation.messages.count).to eq(0)
    expect(ActiveStorage::Attachment.where(record: invoice, name: 'pdf_file').count).to eq(1)
  end

  it 'commits Message and receipt together, then resumes after a post-commit failure without another Message' do
    conversation = billing_conversation
    invoice = generate
    state = described_class.new(invoice)
    allow_any_instance_of(described_class).to receive(:write!).and_wrap_original do |original, name, status, **details|
      raise 'synthetic marker rollback' if name == 'dunning_t_zero' && status == 'completed'

      original.call(name, status, **details)
    end
    service = Billing::NotificationService.new(invoice: invoice)
    expect(service.deliver_dunning_reminder!(stage: 't_zero')).to be(false)
    expect(conversation.messages.count).to eq(0)
    expect(step(invoice, 'dunning_t_zero')['state']).to eq('pending')
    allow_any_instance_of(described_class).to receive(:write!).and_call_original
    expect(service.deliver_dunning_reminder!(stage: 't_zero')).to be(true)
    message_id = step(invoice, 'dunning_t_zero').dig('receipt', 'message_id')
    # The ordinary after_commit pipeline runs after the durable receipt commits.
    expect(service.deliver_dunning_reminder!(stage: 't_zero')).to be(true)
    expect(conversation.messages.pluck(:id)).to eq([message_id])
    expect(state.context['notify']).to be(false)
  end

  it 'does not retarget an invoice after the configured billing conversation changes' do
    original = billing_conversation
    invoice = generate(notify: true)
    replacement = create(:conversation, account: account, inbox: create(:inbox, account: account))
    profile.update!(billing_whatsapp_conversation_id: replacement.id)
    expect(Billing::NotificationService.new(invoice: invoice).deliver_recurring_fallback!).to be(false)
    expect(step(invoice, 'recurring_fallback')['reason']).to eq('changed_or_inaccessible_billing_conversation')
    expect(original.messages.count).to eq(1)
    expect(replacement.messages.count).to eq(0)
  end

  it 'uses one durable Message for each of the four notification callers and gates dunning progress' do
    conversation = billing_conversation
    invoice = generate(notify: true)
    invoice.update!(due_on: Billing.today_almaty)
    Billing::DunningJob.perform_now
    expect(invoice.reload.last_reminder_stage).to eq('t_zero')
    fallback = Billing::NotificationService.new(invoice: invoice)
    2.times { expect(fallback.deliver_recurring_fallback!).to be(true) }
    event = settle(invoice)
    2.times { settle(invoice) }
    expect(conversation.messages.count).to eq(4)
    expect(step(event, 'payment_confirmed').dig('receipt', 'message_id')).to be_present
    expect(invoice.metadata.dig('completion_v1', 'steps', 'payment_confirmed')).to be_nil
  end

  it 'keeps a missing-target dunning stage unset and sends no messages for paid or cancelled invoices' do
    invoice = generate
    invoice.update!(due_on: Billing.today_almaty)
    Billing::DunningJob.perform_now
    expect(invoice.reload.last_reminder_stage).to be_nil
    invoice.update!(status: 'paid')
    expect(Billing::NotificationService.new(invoice: invoice).deliver_dunning_reminder!(stage: 't_zero')).to be(false)
    invoice.update!(status: 'cancelled')
    Billing::InvoiceGeneratorService.resume!(invoice)
    expect(Message.count).to eq(0)
  end

  it 'resumes a committed settlement after dispatch crashes without another financial write or paid_until advance' do
    conversation = billing_conversation
    invoice = generate
    recorder = instance_double(Billing::OwnerFinanceRecorder, record_matched_payment!: nil)
    allow(Billing::OwnerFinanceRecorder).to receive(:new).and_return(recorder)
    allow(Billing::ClosingDocumentsJob).to receive(:perform_later).and_raise('synthetic after settlement')
    expect { settle(invoice) }.to raise_error('synthetic after settlement')
    event = Billing::PaymentEvent.last
    expect(invoice.reload).to be_paid
    paid_until = profile.reload.paid_until
    allow(Billing::ClosingDocumentsJob).to receive(:perform_later).and_return(nil)
    expect(settle(invoice).id).to eq(event.id)
    expect(profile.reload.paid_until).to eq(paid_until)
    expect(recorder).to have_received(:record_matched_payment!).once
    expect(conversation.messages.count).to eq(1)
  end

  it 'serializes two genuine PG invoice and settlement writers without duplicates' do
    billing_conversation
    invoice_ids = parallel_writers { generate.id }
    expect(invoice_ids.uniq.size).to eq(1)
    invoice = Billing::Invoice.find(invoice_ids.first)
    events = parallel_writers { settle(Billing::Invoice.find(invoice.id)).id }
    expect(events.uniq.size).to eq(1)
    expect(Billing::Invoice.count).to eq(1)
    expect(Billing::PaymentEvent.count).to eq(1)
    expect(OwnerFinance::TransactionRecord.count).to eq(1)
    expect(Message.count).to eq(1)
    expect(ActiveStorage::Attachment.where(record: invoice, name: 'pdf_file').count).to eq(1)
  end

  it 'locks Account before an ordinary Profile UPDATE while settlement waits, avoiding the former adverse cycle' do
    invoice = generate
    locked = Queue.new
    settling = Queue.new
    release = Queue.new
    allow_any_instance_of(Billing::AccountProfile).to receive(:sync_account_attributes!).and_wrap_original do |original|
      if Thread.current[:profile_writer]
        locked << ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()')
        release.pop
      end
      original.call
    end
    writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Thread.current[:profile_writer] = true
        Billing::AccountProfile.find(profile.id).update!(payment_overdue_banner: true)
      end
    end
    writer_pid = locked.pop
    settlement = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        connection.execute("SET statement_timeout = '8s'")
        settling << connection.select_value('SELECT pg_backend_pid()')
        settle(Billing::Invoice.find(invoice.id))
      end
    end
    settlement_pid = settling.pop
    Timeout.timeout(5) do
      loop do
        blockers = ActiveRecord::Base.connection.select_value("SELECT pg_blocking_pids(#{settlement_pid.to_i})::text")
        break if blockers.include?(writer_pid.to_s)

        sleep 0.01
      end
    end
    # The callback is paused after Profile UPDATE and before its Account mirror.
    # Settlement waits for the earlier Account lock, so releasing the mirror cannot form a cycle.
    release << true
    writer.value
    expect(settlement.value.status).to eq('matched')
    expect(account.reload.custom_attributes['paid_until']).to eq(profile.reload.paid_until.iso8601)
  ensure
    release << true if release
    writer&.join(10)
    settlement&.join(10)
  end

  it 'rejects stale and late external tokens and never reclaims an ambiguous provider operation' do
    invoice = generate
    state = described_class.new(invoice)
    token = state.claim!('bcc_invoice', configured: true)
    travel 6.minutes do
      expect(state.claim!('bcc_invoice', configured: true)).to be_nil
    end
    expect(step(invoice, 'bcc_invoice')['state']).to eq('needs_review')
    expect(state.finish!('bcc_invoice', token, receipt: { 'provider_id' => 'late' }, attributes: { bcc_external_invoice_id: 'late' })).to be(false)
    expect(invoice.reload.bcc_external_invoice_id).to be_nil
    fresh = Billing::InvoiceGeneratorService.new(account: account, period_start: day + 1.month, notify: false)
    allow(Billing::InvoicePdfGenerator).to receive(:new).and_raise('stop before render')
    expect { fresh.perform }.to raise_error('stop before render')
    state = described_class.new(Billing::Invoice.last)
    state_record = Billing::Invoice.last
    first = state.claim!('pdf', configured: true, irreversible: false)
    second = nil
    travel 6.minutes do
      second = state.claim!('pdf', configured: true, irreversible: false)
    end
    expect(state.finish!('pdf', first, receipt: { 'blob_id' => 1 })).to be(false)
    expect(state.finish!('pdf', second, receipt: { 'blob_id' => 2 })).to be(true)
    expect(state.finish!('pdf', first, receipt: { 'blob_id' => 1 })).to be(false)
    expect(step(state_record, 'pdf').dig('receipt', 'blob_id')).to eq(2)
  end

  it 'holds unknown BCC POST outcomes and invalid responses without a second POST; configuration is retryable' do
    billing_conversation
    invoice = generate
    expect(step(invoice, 'bcc_invoice').values_at('state', 'reason')).to eq(%w[blocked pending_configuration])
    allow(Billing::Config).to receive(:bcc_open_api_configured?).and_return(true)
    client = instance_double(Billing::BccOpenApiClient)
    allow(Billing::BccOpenApiClient).to receive(:new).and_return(client)
    allow(client).to receive(:register_invoice) do
      expect(ActiveRecord::Base.connection.open_transactions).to eq(0)
      raise Billing::BccOpenApiClient::ApiError, 'synthetic unknown HTTP outcome'
    end
    2.times { Billing::InvoiceGeneratorService.resume!(invoice) }
    expect(client).to have_received(:register_invoice).once
    expect(step(invoice, 'bcc_invoice')['state']).to eq('needs_review')
  end

  it 'holds legacy rows and excludes them from scheduled recovery without backfill or bulk sends' do
    conversation = billing_conversation
    invoice = generate
    invoice.update!(metadata: { 'notified' => true, 'notifications' => [{ 'event' => 'invoice_issued' }] })
    event = Billing::PaymentEvent.create!(source: 'manual', bank_reference_id: 'old', amount_minor: 10_000, status: 'matched',
                                          account: account, billing_invoice: invoice, metadata: {})
    Billing::InvoiceGeneratorService.resume!(invoice)
    Billing::PaymentMatcher.resume!(event)
    expect(step(invoice, 'invoice_issued')['reason']).to eq('legacy_without_checkpoint')
    expect(step(event, 'payment_confirmed')['reason']).to eq('legacy_without_checkpoint')
    Billing::GenerateUpcomingInvoicesJob.perform_now
    expect(conversation.messages.count).to eq(0)
    expect(Billing::Invoice.count).to eq(1)
  end

  it 'takes a fresh Profile snapshot under Account lock even if the generator was initialized earlier' do
    service = Billing::InvoiceGeneratorService.new(account: account, notify: false)
    profile.update!(paid_until: day + 2.days, custom_monthly_price_minor: 20_000)
    invoice = service.perform
    expect(invoice.period_start).to eq(day + 2.days)
    expect(invoice.amount_minor).to eq(20_000)
  end

  it 'freezes document inputs for PDF and closing retries, preserving byte-identical same-input PDF output' do
    billing_conversation
    invoice = generate
    allow(Billing::InvoicePdfGenerator).to receive(:new).and_call_original
    legacy_view = invoice.dup
    legacy_view.metadata = {}
    legacy_view.created_at = invoice.created_at
    original_pdf = Billing::InvoicePdfGenerator.new(invoice: invoice).render
    expect(Billing::InvoicePdfGenerator.new(invoice: legacy_view).render).to eq(original_pdf)

    profile.update!(contract_number: 'CHANGED-CONTRACT', billing_tax_id: '000000000000', legal_name: 'Changed payer')
    allow(Billing::Config).to receive_messages(bcc_supplier_name: 'Changed supplier', bcc_supplier_bin: '000000000000')
    expect(Billing::InvoicePdfGenerator.new(invoice: invoice.reload).render).to eq(original_pdf)
    invoice.update!(status: 'paid')
    allow(Billing::Config).to receive(:closing_documents_configured?).and_return(true)
    sigex = instance_double(Billing::SigexClient)
    edo = instance_double(Billing::UchetEdoClient)
    esf = instance_double(Billing::IsEsfClient, issue_esf!: { esf_id: 'SYNTHETIC-ESF' })
    allow(sigex).to receive(:sign_payload!).and_return(cms_signature: 'synthetic')
    allow(edo).to receive(:send_eavr!) do |eavr_payload:, **|
      expect(ActiveRecord::Base.connection.open_transactions).to eq(0)
      expect(eavr_payload).to include(contract_number: 'SYNTHETIC-1', supplier_name: 'Synthetic supplier', supplier_bin: '980123456789',
                                      customer_bin: '210540012345')
      { document_id: 'SYNTHETIC-EDO' }
    end
    service = Billing::ClosingDocumentsService.new(invoice: invoice, sigex_client: sigex, edo_client: edo, esf_client: esf)
    2.times { service.send_eavr! }
    2.times { service.process_counterparty_signature!(signed_at: Time.current) }
    expect(edo).to have_received(:send_eavr!).once
    expect(esf).to have_received(:issue_esf!).once
    expect(step(invoice, 'eavr')['state']).to eq('completed')
    expect(step(invoice, 'esf')['state']).to eq('completed')
  end

  it 'does not POST closing documents again after an unknown response, and holds legacy or missing snapshots' do
    billing_conversation
    invoice = generate
    invoice.update!(status: 'paid')
    allow(Billing::Config).to receive(:closing_documents_configured?).and_return(true)
    sigex = instance_double(Billing::SigexClient, sign_payload!: { cms_signature: 'synthetic' })
    edo = instance_double(Billing::UchetEdoClient)
    allow(edo).to receive(:send_eavr!).and_raise(Billing::UchetEdoClient::ApiError, 'synthetic timeout after POST')
    service = Billing::ClosingDocumentsService.new(invoice: invoice, sigex_client: sigex, edo_client: edo)
    2.times { service.send_eavr! }
    expect(edo).to have_received(:send_eavr!).once
    expect(step(invoice, 'eavr')['state']).to eq('needs_review')

    invoice.update!(metadata: {})
    2.times { service.send_eavr! }
    expect(step(invoice, 'eavr')['reason']).to eq('legacy_without_checkpoint')
    expect(invoice.reload.payer_tax_id).to eq('210540012345')
    expect(edo).to have_received(:send_eavr!).once
  end

  it 'keeps an actual ambiguous BCC HTTP POST on hold rather than repeating it' do
    billing_conversation
    invoice = generate
    allow(Billing::Config).to receive(:bcc_open_api_configured?).and_call_original
    with_modified_env('BCC_OPEN_API_BASE_URL' => 'https://bcc.billing.test', 'BCC_OPEN_API_CLIENT_ID' => 'synthetic-id',
                      'BCC_OPEN_API_CLIENT_SECRET' => 'synthetic-secret') do
      stub_request(:post, 'https://bcc.billing.test/oauth/token').to_return(status: 200, body: { access_token: 'synthetic-token' }.to_json)
      stub_request(:post, 'https://bcc.billing.test/invoices').with do
        expect(ActiveRecord::Base.connection.open_transactions).to eq(0)
        true
      end.to_timeout.then.to_return(status: 200, body: '{}')
      2.times { Billing::InvoiceGeneratorService.resume!(invoice) }
      expect(a_request(:post, 'https://bcc.billing.test/invoices')).to have_been_made.once
      expect(step(invoice, 'bcc_invoice')['state']).to eq('needs_review')
      second = Billing::InvoiceGeneratorService.new(account: account, period_start: day + 1.month, notify: false).perform
      Billing::InvoiceGeneratorService.resume!(second)
      expect(step(second, 'bcc_invoice')['state']).to eq('needs_review')
      expect(a_request(:post, 'https://bcc.billing.test/invoices')).to have_been_made.twice
    end
  end

  it 'blocks an ambiguous recurring charge and resumes a saved approval without charging again' do
    billing_conversation
    profile.update!(autopay_enabled: true, bcc_card_token: 'synthetic-card')
    invoice = generate
    invoice.update!(due_on: Billing.today_almaty)
    allow(Billing::Config).to receive(:bcc_ecom_configured?).and_return(true)
    ecom = instance_double(Billing::BccEcomClient, build_payment_url: 'https://checkout.billing.test')
    allow(Billing::BccEcomClient).to receive(:new).and_return(ecom)
    allow(ecom).to receive(:charge_recurring!).and_return(approved: true, bank_reference_id: 'synthetic-approved',
                                                          raw_payload: { status: 'approved' })
    allow(Billing::PaymentMatcher).to receive(:new).and_raise('synthetic crash after approval receipt')
    Billing::BccRecurringChargeJob.perform_now
    expect(step(invoice, 'recurring_charge_1')['state']).to eq('completed')
    expect(invoice.reload).to be_open
    allow(Billing::PaymentMatcher).to receive(:new).and_call_original
    Billing::BccRecurringChargeJob.perform_now
    expect(invoice.reload).to be_paid
    expect(ecom).to have_received(:charge_recurring!).once
    expect(Billing::PaymentEvent.count).to eq(1)
  end

  it 'never turns a recurring timeout into another charge or a blind decline fallback' do
    billing_conversation
    profile.update!(autopay_enabled: true, bcc_card_token: 'synthetic-card')
    invoice = generate
    invoice.update!(due_on: Billing.today_almaty)
    allow(Billing::Config).to receive(:bcc_ecom_configured?).and_return(true)
    ecom = instance_double(Billing::BccEcomClient)
    allow(Billing::BccEcomClient).to receive(:new).and_return(ecom)
    allow(ecom).to receive(:charge_recurring!).and_raise(Billing::BccEcomClient::ApiError, 'synthetic timeout')
    Billing::BccRecurringChargeJob.perform_now
    travel 2.days do
      Billing::BccRecurringChargeJob.perform_now
    end
    expect(invoice.reload.recurring_attempts_count).to eq(1)
    expect(step(invoice, 'recurring_charge_1')['state']).to eq('needs_review')
    expect(ecom).to have_received(:charge_recurring!).once
    expect(Message.count).to eq(0)
  end

  it 'does not create or charge historical unknown profiles through either automatic job' do
    profile.update!(paid_until: Billing.today_almaty - 1.year, autopay_enabled: true, bcc_card_token: 'synthetic-card')
    allow(Billing::Config).to receive(:bcc_ecom_configured?).and_return(true)
    ecom = instance_double(Billing::BccEcomClient)
    allow(Billing::BccEcomClient).to receive(:new).and_return(ecom)
    expect(ecom).not_to receive(:charge_recurring!)
    expect(Billing::ClosingDocumentsJob).not_to receive(:perform_later)
    expect do
      Billing::GenerateUpcomingInvoicesJob.perform_now
      Billing::BccRecurringChargeJob.perform_now
    end.not_to change(enqueued_jobs, :size)
    expect(Billing::Invoice.count).to eq(0)
    expect(Message.count).to eq(0)
    profile.update!(paid_until: Billing.today_almaty + 6.days)
    Billing::GenerateUpcomingInvoicesJob.perform_now
    expect(Billing::Invoice.count).to eq(0)
  end

  it 'resumes after PDF commit and Message after_commit crashes without another PDF or Message' do
    conversation = billing_conversation
    allow(Billing::NotificationService).to receive(:new).and_raise('synthetic after PDF')
    expect { generate(notify: true) }.to raise_error('synthetic after PDF')
    invoice = Billing::Invoice.last
    expect(invoice.pdf_file).to be_attached
    allow(Billing::NotificationService).to receive(:new).and_call_original
    generate(notify: true)
    expect(Billing::InvoicePdfGenerator).to have_received(:new).once
    expect(conversation.messages.count).to eq(1)
    allow_any_instance_of(Message).to receive(:execute_after_create_commit_callbacks).and_raise('synthetic after Message commit')
    service = Billing::NotificationService.new(invoice: invoice)
    expect(service.deliver_dunning_reminder!(stage: 't_zero')).to be(false)
    expect(step(invoice, 'dunning_t_zero').dig('receipt', 'message_id')).to be_present
    expect(service.deliver_dunning_reminder!(stage: 't_zero')).to be(true)
    expect(conversation.messages.count).to eq(2)
  end

  it 'recovers a blocked closing job and preserves an issued ESF receipt after its deadline' do
    billing_conversation
    invoice = generate
    invoice.update!(status: 'paid')
    allow(Billing::Config).to receive(:closing_documents_configured?).and_return(false)
    Billing::ClosingDocumentsJob.perform_now(invoice.id)
    expect(step(invoice, 'eavr').values_at('state', 'reason')).to eq(%w[blocked pending_configuration])
    expect(invoice.reload.edo_status).to eq('pending_configuration')
    sigex = instance_double(Billing::SigexClient, sign_payload!: { cms_signature: 'synthetic' })
    edo = instance_double(Billing::UchetEdoClient, send_eavr!: { document_id: 'SYNTHETIC-EDO' })
    esf = instance_double(Billing::IsEsfClient, issue_esf!: { esf_id: 'SYNTHETIC-ESF' })
    allow(Billing::SigexClient).to receive(:new).and_return(sigex)
    allow(Billing::UchetEdoClient).to receive(:new).and_return(edo)
    allow(Billing::IsEsfClient).to receive(:new).and_return(esf)
    allow(Billing::Config).to receive(:closing_documents_configured?).and_return(true)
    2.times { Billing::ClosingDocumentsJob.perform_now(invoice.id) }
    Billing::ClosingDocumentsService.process_counterparty_signature!(invoice, signed_at: 2.days.from_now)
    expect(invoice.reload.metadata['esf_turnover_date']).to eq(Billing.today_almaty.iso8601)
    travel 20.days do
      Billing::ClosingDocumentsService.process_counterparty_signature!(invoice, signed_at: Time.current)
    end
    expect(invoice.reload.esf_status).to eq('issued')
    expect(edo).to have_received(:send_eavr!).once
    expect(esf).to have_received(:issue_esf!).once
  end

  it 'holds missing invoice document data instead of backfilling current Profile or supplier fields' do
    billing_conversation
    invoice = generate
    invoice.update!(status: 'paid', payer_tax_id: nil)
    profile.update!(billing_tax_id: '000000000000')
    allow(Billing::Config).to receive(:closing_documents_configured?).and_return(true)
    sigex = instance_double(Billing::SigexClient)
    expect(sigex).not_to receive(:sign_payload!)
    service = Billing::ClosingDocumentsService.new(invoice: invoice, sigex_client: sigex)
    2.times { service.send_eavr! }
    expect(invoice.reload.payer_tax_id).to be_nil
    expect(step(invoice, 'eavr')['state']).to eq('needs_review')
  end

  it 'retries the last declined recurring fallback without charging again or duplicating Message' do
    conversation = billing_conversation
    profile.update!(autopay_enabled: true, bcc_card_token: 'synthetic-card')
    invoice = generate
    state = described_class.new(invoice)
    invoice.update!(recurring_attempts_count: 1)
    token = state.claim!('recurring_charge_2', configured: true)
    state.finish!('recurring_charge_2', token, receipt: { 'approved' => false, 'status' => 'declined', 'raw_payload' => { 'status' => 'declined' } })
    invoice.update!(due_on: Billing.today_almaty, recurring_attempts_count: 2, last_recurring_attempt_at: 2.days.ago)
    allow(Billing::Config).to receive(:bcc_ecom_configured?).and_return(true)
    ecom = instance_double(Billing::BccEcomClient, build_payment_url: 'https://checkout.billing.test')
    allow(Billing::BccEcomClient).to receive(:new).and_return(ecom)
    allow(ecom).to receive(:charge_recurring!).and_return(approved: false, status: 'declined', message: 'Synthetic decline',
                                                          raw_payload: { status: 'declined' })
    allow_any_instance_of(described_class).to receive(:write!).and_wrap_original do |original, name, status, **details|
      raise 'synthetic fallback marker rollback' if name == 'recurring_fallback' && status == 'completed'

      original.call(name, status, **details)
    end
    Billing::BccRecurringChargeJob.perform_now
    expect(conversation.messages.count).to eq(0)
    allow_any_instance_of(described_class).to receive(:write!).and_call_original
    2.times { Billing::BccRecurringChargeJob.perform_now }
    expect(ecom).to have_received(:charge_recurring!).once
    expect(conversation.messages.count).to eq(1)
    expect(invoice.reload.recurring_attempts_count).to eq(3)
    expect(step(invoice, 'recurring_fallback').dig('receipt', 'message_id')).to be_present
  end

  it 'rolls back an owner review task with its marker and resumes without a second settlement' do
    billing_conversation
    invoice = generate
    owner = create(:user, id: 6)
    workspace = create(:account, id: 48)
    create(:account_user, account: workspace, user: owner, role: :administrator)
    allow_any_instance_of(described_class).to receive(:write!).and_wrap_original do |original, name, status, **details|
      raise 'synthetic review marker rollback' if name == 'review_task' && status == 'completed'

      original.call(name, status, **details)
    end
    expect { settle(invoice, amount: 20_000) }.to raise_error('synthetic review marker rollback')
    expect(Crm::Task.count).to eq(0)
    event = Billing::PaymentEvent.last
    paid_until = profile.reload.paid_until
    allow_any_instance_of(described_class).to receive(:write!).and_call_original
    2.times { settle(invoice, amount: 20_000) }
    expect(Crm::Task.count).to eq(1)
    expect(step(event, 'review_task').dig('receipt', 'task_id')).to eq(Crm::Task.last.id)
    expect(OwnerFinance::TransactionRecord.count).to eq(1)
    expect(profile.reload.paid_until).to eq(paid_until)
  end

  it 'rechecks the automatic window under Account lock and never automatically reissues a cancelled period' do
    invoice = generate
    invoice.update!(status: 'cancelled')
    Billing::GenerateUpcomingInvoicesJob.perform_now
    expect(Billing::Invoice.count).to eq(1)
    service = Billing::InvoiceGeneratorService.new(account: account)
    profile.update!(paid_until: Billing.today_almaty - 1.year)
    expect(service.perform(automatic_through: Billing.today_almaty + 5.days)).to be_nil
    profile.update!(paid_until: day, billing_enabled: false)
    expect(service.perform(automatic_through: Billing.today_almaty + 5.days)).to be_nil
    expect(Billing::Invoice.count).to eq(1)
  end

  it 'recovers a managed historical invoice from its snapshot without repricing or creating missed months' do
    billing_conversation
    historical = Billing.today_almaty - 1.year
    profile.update!(paid_until: historical)
    renderer = instance_double(Billing::InvoicePdfGenerator)
    allow(renderer).to receive(:render).and_raise('synthetic historical preparation crash')
    allow(Billing::InvoicePdfGenerator).to receive(:new).and_return(renderer)
    expect do
      Billing::InvoiceGeneratorService.new(account: account, period_start: historical, notify: false).perform
    end.to raise_error('synthetic historical preparation crash')
    invoice = Billing::Invoice.last
    amount = invoice.amount_minor
    profile.update!(custom_monthly_price_minor: 999_999)
    allow(renderer).to receive(:render).and_return('%PDF recovered historical snapshot')
    expect(Billing::InvoiceAmountCalculator).not_to receive(:new)
    Billing::GenerateUpcomingInvoicesJob.perform_now
    expect(invoice.reload.pdf_file).to be_attached
    expect(invoice.amount_minor).to eq(amount)
    expect(Billing::Invoice.count).to eq(1)
    expect(Message.count).to eq(0)
  end

  it 'rejects an unrelated payment Event rather than materializing an invoice through its receipt owner' do
    conversation = billing_conversation
    invoice = generate
    settle(invoice)
    other_account = create(:account)
    Billing::AccountProfile.create!(account: other_account, billing_enabled: true, paid_until: day, custom_monthly_price_minor: 10_000)
    other_invoice = Billing::InvoiceGeneratorService.new(account: other_account, period_start: day, notify: false).perform
    other_event = settle(other_invoice, ref: 'other-synthetic-ref')
    expect(Billing::NotificationService.new(invoice: invoice, payment_event: other_event).deliver_payment_confirmation!).to be(false)
    expect(conversation.messages.count).to eq(1)
  end
end
# rubocop:enable RSpec/AnyInstance, RSpec/MultipleExpectations
