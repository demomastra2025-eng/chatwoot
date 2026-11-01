# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Billing::Config do
  def with_billing_env(overrides)
    previous = overrides.keys.index_with { |key| ENV.fetch(key, nil) }
    overrides.each { |key, val| val.nil? ? ENV.delete(key) : ENV[key] = val }
    yield
  ensure
    previous.each { |key, val| val.nil? ? ENV.delete(key) : ENV[key] = val }
  end

  let(:cleared_env) do
    {
      'BILLING_AUTOBILLING_ENABLED' => nil,
      'BCC_OPEN_API_BASE_URL' => nil,
      'BCC_OPEN_API_CLIENT_ID' => nil,
      'BCC_OPEN_API_CLIENT_SECRET' => nil,
      'BCC_BUSINESS_IBAN' => nil,
      'BCC_ECOM_BASE_URL' => nil,
      'BCC_ECOM_MERCHANT_ID' => nil,
      'BCC_ECOM_TERMINAL_ID' => nil,
      'BCC_ECOM_SECRET_KEY' => nil,
      'UCHET_EDO_BASE_URL' => nil,
      'UCHET_EDO_API_TOKEN' => nil,
      'SIGEX_BASE_URL' => nil,
      'SIGEX_API_TOKEN' => nil,
      'IS_ESF_BASE_URL' => nil,
      'IS_ESF_API_TOKEN' => nil
    }
  end

  it 'defaults to disabled and unconfigured with standard BCC bank defaults' do
    with_billing_env(cleared_env) do
      expect(described_class.autobilling_enabled?).to be(false)
      expect(described_class.bcc_open_api_configured?).to be(false)
      expect(described_class.bcc_ecom_configured?).to be(false)
      expect(described_class.closing_documents_configured?).to be(false)
      expect(described_class.bcc_supplier_bik).to eq('KCJBKZKX')
      expect(described_class.bcc_supplier_kbe).to eq('19')
    end
  end

  it 'detects full configuration for BCC Open API, BCC Ecom, and Closing Documents' do
    configured = cleared_env.merge(
      'BILLING_AUTOBILLING_ENABLED' => 'true',
      'BCC_OPEN_API_BASE_URL' => 'https://api.bcc.kz/v1',
      'BCC_OPEN_API_CLIENT_ID' => 'cid',
      'BCC_OPEN_API_CLIENT_SECRET' => 'csec',
      'BCC_BUSINESS_IBAN' => 'KZ128560000000123456',
      'BCC_ECOM_BASE_URL' => 'https://ecom.bcc.kz',
      'BCC_ECOM_MERCHANT_ID' => 'm1',
      'BCC_ECOM_TERMINAL_ID' => 't1',
      'BCC_ECOM_SECRET_KEY' => 'skey',
      'UCHET_EDO_BASE_URL' => 'https://edo.uchet.kz',
      'UCHET_EDO_API_TOKEN' => 'etok',
      'SIGEX_BASE_URL' => 'https://sigex.kz',
      'SIGEX_API_TOKEN' => 'stok',
      'IS_ESF_BASE_URL' => 'https://esf.gov.kz',
      'IS_ESF_API_TOKEN' => 'itok'
    )
    with_billing_env(configured) do
      expect(described_class.autobilling_enabled?).to be(true)
      expect(described_class.bcc_open_api_configured?).to be(true)
      expect(described_class.bcc_ecom_configured?).to be(true)
      expect(described_class.closing_documents_configured?).to be(true)
    end
  end

  it 'exits all scheduled billing jobs immediately with zero side effects when unconfigured' do
    account = create(:account)
    Billing::AccountProfile.create!(
      account: account, billing_enabled: true, paid_until: Billing.today_almaty + 5.days,
      autopay_enabled: true, bcc_card_token: 'tok_inert'
    )

    with_billing_env(cleared_env) do
      Billing::GenerateUpcomingInvoicesJob.perform_now
      Billing::BccStatementSyncJob.perform_now
      Billing::BccRecurringChargeJob.perform_now
      Billing::DunningJob.perform_now
    end

    expect(Billing::Invoice.count).to eq(0)
    expect(Billing::PaymentEvent.count).to eq(0)
  end
end
