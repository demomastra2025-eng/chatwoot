# frozen_string_literal: true

class Billing::ClosingDocumentsJob < ApplicationJob
  queue_as :low

  def perform(invoice_id)
    invoice = Billing::Invoice.find_by(id: invoice_id)
    return unless invoice&.paid?

    Billing::ClosingDocumentsService.new(invoice: invoice).send_eavr!
  end
end
