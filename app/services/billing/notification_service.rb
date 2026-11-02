# frozen_string_literal: true

class Billing::NotificationService
  def initialize(invoice:, payment_event: nil)
    @invoice = invoice
    @account = invoice.account
    @profile = @account ? Billing::AccountProfile.find_by(account_id: @account.id) : nil
    @payment_event = payment_event
  end

  def deliver_invoice_issued!
    text = "Сформирован счёт № #{@invoice.invoice_number} на сумму #{format_kzt(@invoice.amount_minor)} #{@invoice.currency} " \
           "(срок оплаты до #{@invoice.due_on.strftime('%d.%m.%Y')}).#{payment_link_suffix}"
    deliver!(event: 'invoice_issued', text: text, attach_pdf: true)
  end

  def deliver_payment_confirmation!
    paid_until = @payment_event && Billing::CompletionState.new(@payment_event).context['paid_until']
    paid_until_str = (paid_until ? Date.iso8601(paid_until) : @invoice.period_end).strftime('%d.%m.%Y')
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

    owner = event == 'payment_confirmed' ? @payment_event : @invoice
    return false unless owner

    state = Billing::CompletionState.new(owner)
    return state.hold!(event, 'legacy_without_checkpoint') unless state.managed?

    target = frozen_target(state, event)
    return false unless target

    materialize_delivery!(state, target, event, text, attach_pdf)
  rescue StandardError => e
    Rails.logger.warn("[Billing::NotificationService] Failed conversation delivery for #{@invoice.invoice_number}: #{e.class}")
    false
  end

  def frozen_target(state, event)
    invoice_context = Billing::CompletionState.new(@invoice).context
    return state.block!(event, 'changed_invoice_account') unless invoice_context['account_id'] == @invoice.account_id

    target = invoice_context['target'].to_h
    valid_target?(target) ? target : state.block!(event, 'missing_billing_conversation')
  end

  def valid_target?(target)
    target.values_at('id', 'account_id', 'contact_id', 'inbox_id').all?(&:present?)
  end

  def materialize_delivery!(state, target, event, text, attach_pdf)
    with_delivery_locks(target) do
      state.local!(event, guard: -> { permitted_event?(event) }) do
        conversation = find_scoped_conversation(target)
        next state.block!(event, 'changed_or_inaccessible_billing_conversation') unless conversation
        next state.block!(event, 'pending_pdf') if attach_pdf && !@invoice.pdf_file.attached?

        materialize_message!(conversation, text, attach_pdf)
      end
    end
  end

  def with_delivery_locks(target)
    ActiveRecord::Base.transaction do
      # Message callbacks can use the same identity/Contact/Account hierarchy.
      Contacts::PhoneIdentityLock.acquire!(account_id: target.fetch('account_id'))
      Contact.where(id: target.fetch('contact_id'), account_id: target.fetch('account_id')).order(:id).lock.load
      Account.where(id: [@invoice.account_id, target.fetch('account_id')].uniq.sort).order(:id).lock('FOR NO KEY UPDATE').load
      @invoice.lock!
      yield
    end
  end

  def materialize_message!(conversation, text, attach_pdf)
    msg = conversation.messages.new(account: conversation.account, inbox: conversation.inbox, message_type: :outgoing, content: text)
    attach_invoice_pdf_to_message(msg) if attach_pdf
    msg.save!
    { 'message_id' => msg.id, 'meaning' => 'materialized' }
  end

  def permitted_event?(event)
    expected_account_id = Billing::CompletionState.new(@invoice).context['account_id']
    return false unless expected_account_id == @invoice.account_id
    return false if @invoice.cancelled?
    return @invoice.paid? && matched_payment_event? if event == 'payment_confirmed'

    @invoice.open?
  end

  def matched_payment_event?
    @payment_event.status == 'matched' && @payment_event.billing_invoice_id == @invoice.id && @payment_event.account_id == @invoice.account_id
  end

  def find_scoped_conversation(target)
    profile = Billing::AccountProfile.find_by(account_id: @invoice.account_id)
    return nil unless profile&.billing_enabled? && profile.billing_whatsapp_conversation_id == target['id']

    allowed_account_ids = [@account&.id, OwnerFinance::AccessPolicy.workspace_account_id].compact.uniq
    return nil unless allowed_account_ids.include?(target['account_id'])

    Conversation.joins(:contact, :inbox).where(contacts: { account_id: target['account_id'] }, inboxes: { account_id: target['account_id'] })
                .find_by(id: target['id'], account_id: target['account_id'], inbox_id: target['inbox_id'], contact_id: target['contact_id'])
  end

  def attach_invoice_pdf_to_message(message)
    att = message.attachments.build(account_id: message.account_id, file_type: :file)
    att.file.attach(@invoice.pdf_file.blob)
  end

  def payment_link_suffix
    @invoice.payment_url.present? ? " Ссылка на оплату: #{@invoice.payment_url}" : ''
  end

  def format_kzt(minor)
    whole, tiyn = minor.to_i.divmod(100)
    grouped = whole.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1 ').reverse
    tiyn.zero? ? grouped : format('%<whole>s.%<tiyn>02d', whole: grouped, tiyn: tiyn)
  end
end
