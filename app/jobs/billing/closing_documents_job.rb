# frozen_string_literal: true

class Billing::ClosingDocumentsJob < ApplicationJob
  queue_as :low

  def perform(invoice_id)
    invoice = Billing::Invoice.find_by(id: invoice_id)
    return unless invoice&.paid?

    service = Billing::ClosingDocumentsService.new(invoice: invoice)
    service.send_eavr!
    service.process_counterparty_signature!(signed_at: invoice.signed_by_counterparty_at) if invoice.signed_by_counterparty_at
  end
end
