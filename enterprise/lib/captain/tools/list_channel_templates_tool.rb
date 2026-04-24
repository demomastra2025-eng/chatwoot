class Captain::Tools::ListChannelTemplatesTool < Captain::Tools::BasePublicTool
  description 'List approved channel templates for the current conversation inbox and explain whether templates are required for outside-window WhatsApp delivery'
  param :name, type: 'string', desc: 'Optional exact template name filter', required: false
  param :language, type: 'string', desc: 'Optional template language filter, for example en_US or ru', required: false
  param :status, type: 'string', desc: 'Template status filter. Defaults to approved', required: false
  param :limit, type: 'number', desc: 'Maximum templates to return, capped at 50', required: false

  def perform(tool_context, name: nil, language: nil, status: 'approved', limit: nil)
    conversation = current_conversation(tool_context.state)
    raise ArgumentError, 'Current conversation is not available' if conversation.blank?

    payload = Outbound::ChannelTemplateCatalog.for(
      inbox: conversation.inbox,
      name: name,
      language: language,
      status: status.presence || 'approved',
      limit: normalized_limit(limit)
    )

    JSON.pretty_generate(action: 'list_channel_templates', **payload)
  rescue StandardError => e
    tool_failure(e)
  end

  private

  def normalized_limit(value)
    numeric = value.to_i
    numeric = Outbound::ChannelTemplateCatalog::DEFAULT_LIMIT if numeric <= 0
    [numeric, Outbound::ChannelTemplateCatalog::DEFAULT_LIMIT].min
  end
end
