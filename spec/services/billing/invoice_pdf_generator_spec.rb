# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Billing::InvoicePdfGenerator do
  let(:account) { create(:account, name: 'ЖШС Қазақстан Клиникасы') }
  let(:kazakh_buyer_name) do
    'ЖШС «Қазақстан Денсаулық және Өмір Әділет Ісі — Ұлттық Орталығы №1 (Алматы/Астана)»'
  end
  let(:kazakh_item_desc) do
    'Қызмет көрсету: әділет, ілім, ғылым, өмір, ұлт, үміт, қазақ, кеңес, һақ — пакет 100\100'
  end

  def ensure_kazakh_profile
    Billing::AccountProfile.find_or_create_by!(account: account) do |prof|
      prof.billing_enabled = true
      prof.billing_tax_id = '210540012345'
      prof.legal_name = kazakh_buyer_name
      prof.contract_number = 'КЗ-2026/01–А'
    end
  end

  def build_invoice(line_items: nil)
    ensure_kazakh_profile
    items = line_items || [
      { 'description' => kazakh_item_desc, 'quantity' => 1, 'unit_price_minor' => 19_900_000, 'amount_minor' => 19_900_000 }
    ]
    Billing::Invoice.create!(
      account: account, invoice_number: format('OL-202611-%<id>04d-01', id: account.id),
      status: 'issued', period_start: Date.new(2026, 11, 1), period_end: Date.new(2026, 12, 1),
      due_on: Date.new(2026, 11, 5), currency: 'KZT', base_amount_minor: 19_900_000,
      amount_minor: 19_900_000, partner_commission_base_minor: 19_900_000,
      payer_tax_id: '210540012345', payer_legal_name: kazakh_buyer_name, knp_code: '859',
      payment_purpose: 'Оплата за доступ к платформе OneLink (без НДС)', line_items: items
    )
  end

  def extract_pdf_text(pdf_bytes)
    Tempfile.create(['billing_pdf_spec', '.pdf'], binmode: true) do |tmp|
      tmp.write(pdf_bytes)
      tmp.flush
      `/usr/bin/pdftotext -enc UTF-8 #{tmp.path} -`
    end
  end

  it 'embeds TrueType Type0 CIDFontType2 Identity-H font and extracts all Kazakh glyphs, tenge, and em-dash losslessly' do
    invoice = build_invoice
    pdf_bytes = described_class.new(invoice: invoice).render

    expect(pdf_bytes).to include('/Subtype /Type0', '/Subtype /CIDFontType2', '/Encoding /Identity-H', '/ToUnicode')

    normalized = extract_pdf_text(pdf_bytes).squish
    expect(normalized).to include(kazakh_buyer_name)
    expect(normalized).to include('әділет, ілім, ғылым, өмір, ұлт, үміт, қазақ, кеңес, һақ — пакет 100\100')
    expect(normalized).to include('210540012345', '199 000.00 KZT (₸)', 'КЗ-2026/01–А')
    expect(normalized).not_to match(/[$%?²³]/)
  end

  it 'wraps long lines within A4 width and paginates multi-page invoices without clipping' do
    many_items = Array.new(55) do |idx|
      {
        'description' => format('Қосымша медициналық модуль №%<num>02d — кеңейтілген аналитика және есептілік', num: idx + 1),
        'quantity' => 1,
        'unit_price_minor' => 100_000,
        'amount_minor' => 100_000
      }
    end
    invoice = build_invoice(line_items: many_items)
    pdf_bytes = described_class.new(invoice: invoice).render

    expect(pdf_bytes).to include('/Count 2')
    extracted = extract_pdf_text(pdf_bytes).squish
    expect(extracted).to include('№01', '№55', 'ИТОГО К ОПЛАТЕ (без НДС)')
  end

  it 'uses safe explicit ASCII replacements when font is nil without corrupting digits into $ or %' do
    invoice = build_invoice
    pdf_bytes = described_class.new(invoice: invoice, font: nil).render
    extracted = extract_pdf_text(pdf_bytes).squish

    expect(extracted).to include('210540012345', '199 000.00 KZT (KZT)', 'No.1')
    expect(extracted).not_to match(/[$%]/)
  end
end
