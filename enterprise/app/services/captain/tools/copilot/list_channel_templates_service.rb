class Captain::Tools::Copilot::ListChannelTemplatesService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'list_channel_templates'
  end

  description 'List approved channel templates for a conversation or inbox, and explain whether templates are required for outside-window WhatsApp delivery'
  param :conversation_id, type: :integer, desc: 'Optional conversation display ID or database ID. Defaults to the current conversation',
                          required: false
  param :inbox_id, type: :integer, desc: 'Optional inbox ID. Overrides conversation inbox when provided', required: false
  param :name, type: :string, desc: 'Optional exact template name filter', required: false
  param :language, type: :string, desc: 'Optional template language filter, for example en_US or ru', required: false
  param :status, type: :string, desc: 'Template status filter. Defaults to approved', required: false
  param :limit, type: :number, desc: 'Maximum templates to return, capped at 50', required: false

  def execute(conversation_id: nil, inbox_id: nil, name: nil, language: nil, status: 'approved', limit: nil)
    inbox = resolve_inbox!(conversation_id: conversation_id, inbox_id: inbox_id)
    payload = Outbound::ChannelTemplateCatalog.for(
      inbox: inbox,
      name: name,
      language: language,
      status: status.presence || 'approved',
      limit: parse_limit(limit, default: Outbound::ChannelTemplateCatalog::DEFAULT_LIMIT, max: Outbound::ChannelTemplateCatalog::DEFAULT_LIMIT)
    )

    formatted_payload(action: 'list_channel_templates', **payload)
  rescue StandardError => e
    tool_failure(e)
  end

  private

  def resolve_inbox!(conversation_id:, inbox_id:)
    return account.inboxes.find(inbox_id) if inbox_id.present?

    conversation = conversation_id.present? ? find_permissible_conversation!(conversation_id) : current_conversation
    raise ArgumentError, 'conversation_id or inbox_id is required to list channel templates' if conversation.blank?

    conversation.inbox
  end
end
