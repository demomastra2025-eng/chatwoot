# frozen_string_literal: true

class Billing::NotificationService
  def initialize(invoice:)
    @invoice = invoice
    @account = invoice.account
    @profile = @account&.billing_account_profile
  end

  def deliver_invoice_issued!
    text = "Сформирован счёт № #{@invoice.invoice_number} на сумму #{format_kzt(@invoice.amount_minor)} #{@invoice.currency} " \
           "(срок оплаты до #{@invoice.due_on.strftime('%d.%m.%Y')}).#{payment_link_suffix}"
    deliver!(event: 'invoice_issued', text: text, attach_pdf: true)
  end

  def deliver_payment_confirmation!
    paid_until_str = (@profile&.reload&.paid_until || @invoice.period_end).strftime('%d.%m.%Y')
    text = "Оплата по счёту № #{@invoice.invoice_number} получена, доступ OneLink продлён до #{paid_until_str}."
    deliver!(event: 'payment_confirmed', text: text, attach_pdf: false)
  end

  def deliver_dunning_reminder!(stage:)
    prefix = stage == 't_zero' ? 'Сегодня срок оплаты' : 'Напоминание о предстоящей оплате'
    text = "#{prefix} по счёту № #{@invoice.invoice_number} на сумму #{format_kzt(@invoice.amount_minor)} #{@invoice.currency} " \
           "(до #{@invoice.due_on.strftime('%d.%m.%Y')}).#{payment_link_suffix}"
    deliver!(event: "dunning_#{stage}", text: text, attach_pdf: false)
  end

  def deliver_recurring_fallback!
    text = "Не удалось выполнить автосписание по карте для счёта № #{@invoice.invoice_number}. " \
           "Пожалуйста, оплатите по реквизитам в PDF-счёте.#{payment_link_suffix}"
    deliver!(event: 'recurring_fallback', text: text, attach_pdf: true)
  end

  private

  def deliver!(event:, text:, attach_pdf:)
    return false unless Billing::Config.autobilling_enabled?

    dispatched = dispatch_to_billing_conversation(text, attach_pdf)
    record_notification_audit!(event, dispatched)
    true
  end

  def dispatch_to_billing_conversation(text, attach_pdf)
    conv_id = @profile&.billing_whatsapp_conversation_id
    return false if conv_id.blank?

    conversation = Conversation.find_by(id: conv_id)
    return false unless conversation

    msg = conversation.messages.new(account: conversation.account, inbox: conversation.inbox, message_type: :outgoing, content: text)
    attach_invoice_pdf_to_message(msg) if attach_pdf && @invoice.pdf_file.attached?
    msg.save!
    true
  rescue StandardError => e
    Rails.logger.warn("[Billing::NotificationService] Failed conversation delivery for #{@invoice.invoice_number}: #{e.class}")
    false
  end

  def attach_invoice_pdf_to_message(message)
    att = message.attachments.build(account_id: message.account_id, file_type: :file)
    att.file.attach(@invoice.pdf_file.blob)
  end

  def record_notification_audit!(event, conversation_sent)
    history = Array(@invoice.metadata['notifications']).last(19)
    history << {
      'event' => event,
      'at' => Time.current.iso8601,
      'conversation_sent' => conversation_sent
    }
    @invoice.update!(metadata: @invoice.metadata.merge('notifications' => history))
  end

  def payment_link_suffix
    @invoice.payment_url.present? ? " Ссылка на оплату: #{@invoice.payment_url}" : ''
  end

  def format_kzt(minor)
    whole = minor.to_i / 100
    whole.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1 ').reverse
  end
end
