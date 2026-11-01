# frozen_string_literal: true

class Api::V1::Accounts::Billing::InvoicesController < Api::V1::Accounts::BaseController
  before_action :check_admin_authorization?
  before_action :fetch_invoice, only: %i[show pdf]

  def index
    limit = (params[:limit].presence || 25).to_i.clamp(1, 100)
    invoices = Current.account.billing_invoices.recent.limit(limit)
    render json: {
      meta: profile_meta_payload,
      payload: invoices.map(&:as_api_payload)
    }
  end

  def show
    render json: @invoice.as_api_payload
  end

  def pdf
    return head :not_found unless @invoice.pdf_file.attached?

    redirect_to rails_blob_path(@invoice.pdf_file, disposition: 'inline')
  end

  private

  def fetch_invoice
    @invoice = Current.account.billing_invoices.find(params[:id])
  end

  def profile_meta_payload
    profile = Current.account.billing_account_profile
    {
      billing_enabled: profile&.billing_enabled || false,
      paid_until: profile&.paid_until&.iso8601,
      autopay_enabled: profile&.autopay_enabled || false,
      bcc_card_masked: profile&.bcc_card_masked,
      payment_overdue_banner: profile&.payment_overdue_banner || false,
      overdue_invoice_number: profile&.overdue_invoice_number
    }
  end
end
