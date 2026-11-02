# frozen_string_literal: true

require 'rails_helper'

# Real HTTP normalization, durable proof and the existing atomic matcher pipeline.
# rubocop:disable RSpec/AnyInstance
RSpec.describe Billing::BccRecurringChargeJob do
  self.use_transactional_tests = false

  let(:account) { create(:account) }
  let(:day) { Billing.today_almaty + 4.days }
  let!(:profile) do
    Billing::AccountProfile.create!(account: account, billing_enabled: true, paid_until: day, custom_monthly_price_minor: 10_000,
                                    legal_name: 'Synthetic payer', billing_tax_id: '210540012345', contract_number: 'PROOF-1')
  end

  before do
    WebMock.disable_net_connect!
    allow(Billing::Config).to receive_messages(autobilling_enabled?: true, bcc_open_api_configured?: false, bcc_ecom_configured?: false,
                                               closing_documents_configured?: false, bcc_supplier_name: 'Synthetic supplier',
                                               bcc_supplier_bin: '980123456789', bcc_business_iban: 'KZ000000000000000000')
    allow(Billing::InvoicePdfGenerator).to receive(:new).and_return(instance_double(Billing::InvoicePdfGenerator, render: '%PDF proof'))
  end

  def generate(for_account: account, period: day)
    invoice = Billing::InvoiceGeneratorService.new(account: for_account, period_start: period, notify: false).perform
    invoice.update!(due_on: Billing.today_almaty)
    invoice
  end

  def enable_ecom(for_profile: profile)
    allow(Billing::Config).to receive_messages(bcc_ecom_configured?: true, bcc_ecom_base_url: 'https://ecom.proof.test',
                                               bcc_ecom_merchant_id: 'synthetic-merchant', bcc_ecom_terminal_id: 'synthetic-terminal',
                                               bcc_ecom_secret_key: 'synthetic-secret')
    for_profile.update!(autopay_enabled: true, bcc_card_token: 'synthetic-card')
  end

  def charge_step(invoice)
    invoice.reload.metadata.dig('completion_v1', 'steps', 'recurring_charge_1')
  end

  def seed_approved(invoice, reference: 'raw-provider-reference', raw: nil)
    raw ||= { 'approved' => true, 'bank_reference_id' => reference }
    receipt = { 'approved' => true, 'bank_reference_id' => reference, 'raw_payload' => raw }
    state = Billing::CompletionState.new(invoice)
    token = state.claim!('recurring_charge_1', configured: true)
    expect(token).to be_present
    expect(state.finish!('recurring_charge_1', token, receipt: receipt)).to be(true)
    invoice.update!(recurring_attempts_count: 1, last_recurring_attempt_at: 25.hours.ago)
    receipt
  end

  def match(invoice, reference:, expected: invoice)
    Billing::PaymentMatcher.new(source: 'bcc_ecom', expected_invoice: expected, payload: {
                                  bank_reference_id: reference, invoice_number: invoice.invoice_number,
                                  amount_minor: invoice.amount_minor, currency: invoice.currency
                                }).perform
  end

  def real_approval(reference)
    stub_request(:post, 'https://ecom.proof.test/recurring/charge').with do
      expect(ActiveRecord::Base.connection.open_transactions).to eq(0)
      true
    end.to_return(status: 200, body: { approved: true, bank_reference_id: reference }.to_json)
  end

  it 'holds a partial normalized reference mutation before any financial DML and preserves its audit receipt' do
    invoice = generate
    enable_ecom
    original = seed_approved(invoice)
    metadata = invoice.reload.metadata.deep_dup
    metadata['completion_v1']['steps']['recurring_charge_1']['receipt']['bank_reference_id'] = 'different-normalized-reference'
    invoice.update!(metadata: metadata)
    2.times { described_class.perform_now }
    expect([invoice.reload.status, Billing::PaymentEvent.count, OwnerFinance::TransactionRecord.count]).to eq(['issued', 0, 0])
    expect(profile.reload.paid_until).to eq(day)
    expect(charge_step(invoice)['state']).to eq('needs_review')
    expect(charge_step(invoice)['receipt']['raw_payload']).to eq(original['raw_payload'])
    expect(charge_step(invoice)['receipt']['bank_reference_id']).to eq('different-normalized-reference')
    expect(WebMock::RequestRegistry.instance.requested_signatures.hash).to be_empty
  end

  it 'holds an approved saved receipt without real raw reference proof and never retries debit' do
    invoice = generate
    enable_ecom
    seed_approved(invoice, raw: { 'approved' => true, 'status' => 'approved' })
    2.times { described_class.perform_now }
    expect([invoice.reload.status, invoice.recurring_attempts_count, charge_step(invoice)['state']]).to eq(['issued', 1, 'needs_review'])
    expect([Billing::PaymentEvent.count, OwnerFinance::TransactionRecord.count, profile.reload.paid_until]).to eq([0, 0, day])
    expect(WebMock::RequestRegistry.instance.requested_signatures.hash).to be_empty
  end

  it 'holds a live approval missing its raw reference after one real HTTP request' do
    invoice = generate
    enable_ecom
    request = stub_request(:post, 'https://ecom.proof.test/recurring/charge')
              .to_return(status: 200, body: { approved: true, status: 'approved' }.to_json)
    2.times { described_class.perform_now }
    expect([invoice.reload.status, invoice.recurring_attempts_count, charge_step(invoice)['state']]).to eq(['issued', 1, 'needs_review'])
    expect([Billing::PaymentEvent.count, OwnerFinance::TransactionRecord.count, profile.reload.paid_until]).to eq([0, 0, day])
    expect(request).to have_been_requested.once
  end

  it 'holds a duplicate real provider reference for a different Invoice without resuming its foreign Event' do
    first = generate
    enable_ecom
    request = real_approval('same-provider-reference')
    described_class.perform_now
    event = Billing::PaymentEvent.sole
    paid_until = profile.reload.paid_until
    second = generate(period: day + 1.month)
    allow(Billing::PaymentMatcher).to receive(:resume!).and_call_original
    2.times { described_class.perform_now }
    expect([first.reload.status, second.reload.status, charge_step(second)['state']]).to eq(%w[paid issued needs_review])
    expect(Billing::PaymentEvent.pluck(:id, :billing_invoice_id)).to eq([[event.id, first.id]])
    expect([OwnerFinance::TransactionRecord.count, profile.reload.paid_until]).to eq([1, paid_until])
    expect(charge_step(second).dig('receipt', 'raw_payload', 'bank_reference_id')).to eq('same-provider-reference')
    expect(Billing::PaymentMatcher).not_to have_received(:resume!)
    expect([Message.count, Crm::Task.count]).to eq([0, 0])
    expect(request).to have_been_requested.twice
  end

  it 'holds an entire valid receipt copied from another account before any foreign Event resume' do
    first = generate
    enable_ecom
    request = real_approval('copied-receipt')
    described_class.perform_now
    foreign = create(:account)
    foreign_profile = Billing::AccountProfile.create!(account: foreign, billing_enabled: true, paid_until: day,
                                                      custom_monthly_price_minor: 10_000, legal_name: 'Other synthetic payer')
    second = generate(for_account: foreign)
    receipt = charge_step(first).fetch('receipt')
    seed_approved(second, reference: receipt.fetch('bank_reference_id'), raw: receipt.fetch('raw_payload'))
    allow(Billing::PaymentMatcher).to receive(:resume!).and_call_original
    2.times { described_class.new.resume_approved! }
    expect([second.reload.status, charge_step(second)['state'], foreign_profile.reload.paid_until]).to eq(['issued', 'needs_review', day])
    expect(charge_step(second)['receipt']).to include(receipt.slice('approved', 'bank_reference_id', 'raw_payload'))
    expect([Billing::PaymentEvent.count, OwnerFinance::TransactionRecord.count]).to eq([1, 1])
    expect(Billing::PaymentMatcher).not_to have_received(:resume!)
    expect(request).to have_been_requested.once
  end

  %w[bank_reference_id reference_id rrn transaction_id].each_with_index do |key, index|
    it "uses the real normalizer for approved alias #{key} and numeric reference during local recovery" do
      invoice = generate
      enable_ecom
      raw = { 'status' => ' APPROVED ', key => 7000 + index }
      request = stub_request(:post, 'https://ecom.proof.test/recurring/charge').to_return(status: 200, body: raw.to_json)
      allow(Billing::PaymentMatcher).to receive(:new).and_raise('stop after saved approval')
      described_class.perform_now
      expect(charge_step(invoice).dig('receipt', 'bank_reference_id')).to eq((7000 + index).to_s)
      profile.update!(billing_enabled: false, autopay_enabled: false, bcc_card_token: nil)
      allow(Billing::Config).to receive_messages(autobilling_enabled?: false, bcc_ecom_configured?: false)
      allow(Billing::PaymentMatcher).to receive(:new).and_call_original
      2.times { described_class.perform_now }
      expect([invoice.reload.status, Billing::PaymentEvent.count, OwnerFinance::TransactionRecord.count]).to eq(['paid', 1, 1])
      expect(Billing::PaymentEvent.sole.bank_reference_id).to eq((7000 + index).to_s)
      expect(profile.reload.paid_until).to eq(invoice.period_end)
      expect(request).to have_been_requested.once
    end
  end

  it 'preserves the exact existing normalizer aliases precedence defaults and card-token filtering' do
    normalized = Billing::BccEcomClient.normalize_charge_response(
      'approved' => true, 'bank_reference_id' => ' first ', 'reference_id' => 'second', 'rrn' => 123,
      'transaction_id' => 'fourth', 'card_token' => 'synthetic-card', 'message' => 'a' * 170
    )
    expect(normalized).to include(approved: true, bank_reference_id: 'first', status: 'declined', message: 'a' * 160)
    expect(normalized[:raw_payload]).not_to have_key('card_token')
    expect(Billing::BccEcomClient.normalize_charge_response('message' => 'unknown')).to include(approved: false, bank_reference_id: nil,
                                                                                                status: 'declined')
    expect(Billing::BccEcomClient.normalize_charge_response('response_code' => '00',
                                                            'rrn' => 701)).to include(
                                                              approved: true, bank_reference_id: '701', status: '00'
                                                            )
  end

  it 'replays an exact same invoice and reference through the matcher without a second financial write' do
    invoice = generate
    first = match(invoice, reference: 'same-invoice-replay')
    paid_until = profile.reload.paid_until
    2.times { expect(match(invoice, reference: 'same-invoice-replay').id).to eq(first.id) }
    expect([Billing::PaymentEvent.count, OwnerFinance::TransactionRecord.count]).to eq([1, 1])
    expect(profile.reload.paid_until).to eq(paid_until)
  end

  it 'checks an Event discovered only inside the Account and Invoice transaction before financial DML' do
    first = generate
    event = match(first, reference: 'discovered-after-lock')
    second = generate(period: day + 1.month)
    seed_approved(second, reference: event.bank_reference_id)
    calls = 0
    allow_any_instance_of(Billing::PaymentMatcher).to receive(:find_existing_event).and_wrap_original do |original|
      calls += 1
      calls == 1 ? nil : original.call
    end
    allow(Billing::PaymentMatcher).to receive(:resume!).and_call_original
    described_class.new.resume_approved!
    expect([second.reload.status, charge_step(second)['state']]).to eq(%w[issued needs_review])
    expect([Billing::PaymentEvent.count, OwnerFinance::TransactionRecord.count]).to eq([1, 1])
    expect(Billing::PaymentMatcher).not_to have_received(:resume!)
    expect(WebMock::RequestRegistry.instance.requested_signatures.hash).to be_empty
  end

  it 'refuses a trusted expected Invoice different from the explicit payload Invoice before DML or resume' do
    first = generate
    second = generate(period: day + 1.month)
    allow(Billing::PaymentMatcher).to receive(:resume!).and_call_original
    expect { match(first, reference: 'wrong-explicit-invoice', expected: second) }
      .to raise_error(Billing::PaymentMatcher::CorrelationError)
    expect([first.reload.status, second.reload.status, profile.reload.paid_until]).to eq(['issued', 'issued', day])
    expect([Billing::PaymentEvent.count, OwnerFinance::TransactionRecord.count, Message.count, Crm::Task.count]).to eq([0, 0, 0, 0])
    expect(Billing::PaymentMatcher).not_to have_received(:resume!)
    expect(WebMock::RequestRegistry.instance.requested_signatures.hash).to be_empty
  end

  it 'preserves general statement and webhook replay semantics without the trusted correlation option' do
    first = generate
    event = match(first, reference: 'general-existing-reference')
    second = generate(period: day + 1.month)
    expect(match(second, reference: event.bank_reference_id, expected: nil).id).to eq(event.id)
    expect([second.reload.status, Billing::PaymentEvent.count, OwnerFinance::TransactionRecord.count]).to eq(['issued', 1, 1])
  end

  it 'permits a genuine explicit decline followed by exactly one next approved debit' do
    invoice = generate
    enable_ecom
    request = stub_request(:post, 'https://ecom.proof.test/recurring/charge')
              .to_return(status: 200, body: { status: 'declined' }.to_json)
              .then.to_return(status: 200, body: { approved: true, reference_id: 702 }.to_json)
    described_class.perform_now
    travel 25.hours do
      2.times { described_class.perform_now }
    end
    expect([invoice.reload.status, invoice.recurring_attempts_count]).to eq(['paid', 2])
    expect([Billing::PaymentEvent.count, OwnerFinance::TransactionRecord.count]).to eq([1, 1])
    expect(profile.reload.paid_until).to eq(invoice.period_end)
    expect(request).to have_been_requested.twice
  end

  def pause_finance_inserts(ready, release, unique_errors)
    allow_any_instance_of(OwnerFinance::TransactionRecord).to receive(:_create_record).and_wrap_original do |original, *arguments|
      ready << ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()')
      release.pop
      begin
        original.call(*arguments)
      rescue ActiveRecord::RecordNotUnique => e
        unique_errors << unique_violation(e)
        raise
      end
    end
  end

  def unique_violation(error)
    result = error.cause.result
    { error: error.class.name, table: result.error_field(PG::Result::PG_DIAG_TABLE_NAME),
      index: result.error_field(PG::Result::PG_DIAG_CONSTRAINT_NAME) }
  end

  def observe_unique_race(pids, errors, results)
    proof = errors.pop(true)
    puts "PROOF_OBSERVATION unique_reference_race: #{proof.merge(pids: pids, results: results).to_json}"
    expect([errors.size, proof]).to eq([0, { error: 'ActiveRecord::RecordNotUnique', table: 'owner_finance_transactions',
                                             index: 'index_owner_finance_transactions_on_external_source_key' }])
  end

  def charge_thread(invoice)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        connection.execute("SET statement_timeout = '8s'")
        described_class.new.send(:attempt_charge_for!, Billing::Invoice.find(invoice.id))
        :settled
      rescue Billing::PaymentMatcher::CorrelationError
        :correlation_hold
      ensure
        connection.execute("SET statement_timeout = '14s'")
      end
    end
  end

  def finish_race_threads(threads, release)
    2.times { release << true } if release
    threads&.each { |thread| thread.join(10) }
  end

  def race_charge_threads(invoices)
    ready = Queue.new
    release = Queue.new
    unique_errors = Queue.new
    pause_finance_inserts(ready, release, unique_errors)
    threads = invoices.map { |invoice| charge_thread(invoice) }
    pids = Array.new(2) { Timeout.timeout(15) { ready.pop } }
    expect(pids.uniq.size).to eq(2)
    2.times { release << true }
    results = threads.map(&:value)
    observe_unique_race(pids, unique_errors, results)
    results
  ensure
    finish_race_threads(threads, release)
  end

  it 'rolls back a real unique-reference race before accepting a foreign Event and holds only the losing approval' do
    first = generate
    other = create(:account)
    other_profile = Billing::AccountProfile.create!(account: other, billing_enabled: true, paid_until: day,
                                                    custom_monthly_price_minor: 10_000, legal_name: 'Race second payer')
    second = generate(for_account: other)
    enable_ecom
    enable_ecom(for_profile: other_profile)
    request = real_approval('concurrent-provider-reference')
    expect(race_charge_threads([first, second]).sort).to eq(%i[correlation_hold settled])
    winner = Billing::Invoice.find_by!(status: 'paid')
    loser = Billing::Invoice.find_by!(status: 'issued')
    expect([Billing::PaymentEvent.pluck(:billing_invoice_id), OwnerFinance::TransactionRecord.count, Message.count, Crm::Task.count])
      .to eq([[winner.id], 1, 0, 0])
    expect([loser.bank_reference_id, loser.paid_at, charge_step(loser)['state']]).to eq([nil, nil, 'needs_review'])
    expect(charge_step(loser).dig('receipt', 'bank_reference_id')).to eq('concurrent-provider-reference')
    expect(Billing::AccountProfile.find_by!(account_id: loser.account_id).paid_until).to eq(day)
    expect(Billing::AccountProfile.find_by!(account_id: winner.account_id).paid_until).to eq(winner.period_end)
    described_class.perform_now
    expect(request).to have_been_requested.twice
  end

  it 'accepts both actual PG writers for an exact same-invoice reference while settling once' do
    invoice = generate
    ready = Queue.new
    release = Queue.new
    threads = Array.new(2) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          connection.execute("SET statement_timeout = '8s'")
          ready << connection.select_value('SELECT pg_backend_pid()')
          release.pop
          match(Billing::Invoice.find(invoice.id), reference: 'same-invoice-pg-race').id
        ensure
          connection.execute("SET statement_timeout = '14s'")
        end
      end
    end
    expect(Array.new(2) { Timeout.timeout(10) { ready.pop } }.uniq.size).to eq(2)
    2.times { release << true }
    expect(threads.map(&:value).uniq.size).to eq(1)
    expect([invoice.reload.status, Billing::PaymentEvent.count, OwnerFinance::TransactionRecord.count]).to eq(['paid', 1, 1])
    expect(profile.reload.paid_until).to eq(invoice.period_end)
  ensure
    finish_race_threads(threads, release)
  end
end
# rubocop:enable RSpec/AnyInstance
