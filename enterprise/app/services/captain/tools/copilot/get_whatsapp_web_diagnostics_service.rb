class Captain::Tools::Copilot::GetWhatsappWebDiagnosticsService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'get_whatsapp_web_diagnostics'
  end

  description 'Get runtime diagnostics for a WhatsApp Web inbox'
  param :inbox_id, type: :integer, desc: 'Inbox ID', required: true

  def execute(inbox_id:)
    inbox = whatsapp_web_inbox!(inbox_id)

    formatted_payload(
      action: 'get_whatsapp_web_diagnostics',
      inbox_id: inbox.id,
      inbox_name: inbox.name,
      diagnostics: inbox.channel.diagnostics
    )
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    account_administrator?
  end

  private

  def whatsapp_web_inbox!(inbox_id)
    inbox = account.inboxes.find(inbox_id)
    raise ArgumentError, 'Inbox is not a WhatsApp Web inbox' unless inbox.channel.is_a?(::Channel::WhatsappWeb)

    inbox
  end
end
