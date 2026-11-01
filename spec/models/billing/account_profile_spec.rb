# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Billing::AccountProfile do
  let(:account) { create(:account, custom_attributes: { 'existing_flag' => 'keep_me' }) }

  it 'defaults partner_commission_rate_pct to 0 and never leaks bcc_card_token in serialization or inspect' do
    profile = described_class.create!(account: account, bcc_card_token: 'tok_super_secret_card_999')

    expect(profile.partner_commission_rate_pct).to eq(0)
    expect(profile.serializable_hash.keys).not_to include('bcc_card_token', :bcc_card_token)
    expect(profile.as_json.keys).not_to include('bcc_card_token')
    expect(profile.to_json).not_to include('tok_super_secret_card_999')
    expect(profile.inspect).to include('[FILTERED]')
    expect(profile.inspect).not_to include('tok_super_secret_card_999')
  end

  it 'destroys profile and invoices synchronously on account.destroy! while nullifying payment events' do
    profile = described_class.create!(account: account, billing_enabled: true, paid_until: Date.new(2026, 11, 25))
    Accounts::ApplyPlan.new(account: account, tariff: 'text_call').call
    invoice = Billing::InvoiceGeneratorService.new(account: account, period_start: Date.new(2026, 11, 25), notify: false).perform
    event = Billing::PaymentEvent.create!(
      account: account, billing_invoice: invoice, source: 'bcc_open_api',
      bank_reference_id: 'REF-DESTROY-1', status: 'matched', amount_minor: invoice.amount_minor, currency: 'KZT'
    )

    expect { account.destroy! }.not_to raise_error
    expect(described_class.exists?(profile.id)).to be(false)
    expect(Billing::Invoice.exists?(invoice.id)).to be(false)
    expect(event.reload).to have_attributes(account_id: nil, billing_invoice_id: nil)
  end

  it 'aligns late payment paid_until to invoice period without shifting billing_day and checks remaining overdue invoices' do
    Accounts::ApplyPlan.new(account: account, tariff: 'text_call').call
    profile = described_class.create!(
      account: account, billing_enabled: true, paid_until: Date.new(2026, 10, 25),
      billing_day: 25, payment_overdue_banner: true, overdue_invoice_number: 'OLD'
    )
    older_overdue = Billing::InvoiceGeneratorService.new(account: account, period_start: Date.new(2026, 10, 25), notify: false).perform
    newer_overdue = Billing::InvoiceGeneratorService.new(account: account, period_start: Date.new(2026, 11, 25), notify: false).perform
    older_overdue.update!(status: 'overdue')
    newer_overdue.update!(status: 'overdue')

    older_overdue.update!(status: 'paid')
    profile.advance_paid_until!(paid_date: Date.new(2026, 11, 4), invoice: older_overdue)
    expect(profile.reload).to have_attributes(
      paid_until: Date.new(2026, 11, 25), billing_day: 25,
      payment_overdue_banner: true, overdue_invoice_number: newer_overdue.invoice_number
    )

    newer_overdue.update!(status: 'paid')
    profile.advance_paid_until!(paid_date: Date.new(2026, 12, 2), invoice: newer_overdue)
    expect(profile.reload).to have_attributes(
      paid_until: Date.new(2026, 12, 25), billing_day: 25,
      payment_overdue_banner: false, overdue_invoice_number: nil
    )
  end

  it 'patches accounts.custom_attributes atomically in SQL without clobbering concurrent JSONB keys' do
    profile = described_class.create!(account: account, paid_until: Date.new(2026, 11, 25))
    ActiveRecord::Base.connection.execute(
      "UPDATE accounts SET custom_attributes = custom_attributes || '{\"concurrent_ai_counter\": 42}'::jsonb WHERE id = #{account.id}"
    )

    profile.update!(paid_until: Date.new(2026, 12, 25), payment_overdue_banner: false)

    attrs = account.reload.custom_attributes
    expect(attrs['concurrent_ai_counter']).to eq(42)
    expect(attrs['existing_flag']).to eq('keep_me')
    expect(attrs['paid_until']).to eq('2026-12-25')
    expect(attrs.key?('overdue_invoice_number')).to be(false)
  end
end
