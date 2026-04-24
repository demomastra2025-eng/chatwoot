class Captain::Tools::Copilot::ReconnectWhatsappWebService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'reconnect_whatsapp_web'
  end

  description 'Reconnect a WhatsApp Web inbox'
  param :inbox_id, type: :integer, desc: 'Inbox ID', required: true

  def execute(inbox_id:)
    inbox = whatsapp_web_inbox!(inbox_id)
    inbox.channel.reconnect!
    inbox.reload

    formatted_payload(
      action: 'reconnect_whatsapp_web',
      inbox: whatsapp_web_inbox_payload(inbox)
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

  def whatsapp_web_inbox_payload(inbox)
    {
      id: inbox.id,
      name: inbox.name,
      channel_type: inbox.channel_type,
      phone_number: inbox.channel.phone_number,
      lifecycle_state: inbox.channel.lifecycle_state,
      connection_state: inbox.channel.connection_state,
      last_error: inbox.channel.last_error,
      updated_at: inbox.updated_at&.iso8601
    }
  end
end
