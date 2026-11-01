# frozen_string_literal: true

class Billing::Config
  DEFAULT_BIK = 'KCJBKZKX'
  DEFAULT_KBE = '19'
  DEFAULT_KNP = '859'

  class << self
    def autobilling_enabled?
      ENV['BILLING_AUTOBILLING_ENABLED'] == 'true'
    end

    def bcc_open_api_configured?
      [bcc_open_api_base_url, bcc_open_api_client_id, bcc_open_api_client_secret, bcc_business_iban].all?(&:present?)
    end

    def bcc_ecom_configured?
      [bcc_ecom_base_url, bcc_ecom_merchant_id, bcc_ecom_terminal_id, bcc_ecom_secret_key].all?(&:present?)
    end

    def edo_configured?
      [uchet_edo_base_url, uchet_edo_api_token, sigex_base_url, sigex_api_token].all?(&:present?)
    end

    def esf_configured?
      [esf_base_url, esf_api_token].all?(&:present?)
    end

    def closing_documents_configured?
      edo_configured? && esf_configured?
    end

    def bcc_open_api_base_url = env_str('BCC_OPEN_API_BASE_URL')
    def bcc_open_api_client_id = env_str('BCC_OPEN_API_CLIENT_ID')
    def bcc_open_api_client_secret = env_str('BCC_OPEN_API_CLIENT_SECRET')
    def bcc_business_iban = env_str('BCC_BUSINESS_IBAN')

    def bcc_supplier_name = env_str('BCC_SUPPLIER_NAME') || 'OneLink'
    def bcc_supplier_bin = env_str('BCC_SUPPLIER_BIN')
    def bcc_supplier_bik = env_str('BCC_SUPPLIER_BIK') || DEFAULT_BIK
    def bcc_supplier_kbe = env_str('BCC_SUPPLIER_KBE') || DEFAULT_KBE

    def bcc_ecom_base_url = env_str('BCC_ECOM_BASE_URL')
    def bcc_ecom_merchant_id = env_str('BCC_ECOM_MERCHANT_ID')
    def bcc_ecom_terminal_id = env_str('BCC_ECOM_TERMINAL_ID')
    def bcc_ecom_secret_key = env_str('BCC_ECOM_SECRET_KEY')

    def uchet_edo_base_url = env_str('UCHET_EDO_BASE_URL')
    def uchet_edo_api_token = env_str('UCHET_EDO_API_TOKEN')
    def sigex_base_url = env_str('SIGEX_BASE_URL')
    def sigex_api_token = env_str('SIGEX_API_TOKEN')
    def esf_base_url = env_str('IS_ESF_BASE_URL')
    def esf_api_token = env_str('IS_ESF_API_TOKEN')

    private

    def env_str(key)
      ENV.fetch(key, nil).to_s.strip.presence
    end
  end
end
