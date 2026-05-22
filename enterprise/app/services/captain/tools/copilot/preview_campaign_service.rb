class Captain::Tools::Copilot::PreviewCampaignService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'preview_campaign'
  end

  description 'Preview how a campaign would resolve for a selected inbox and audience'
  param :inbox_id, type: :integer, desc: 'Inbox ID', required: true
  param :audience, type: :object, desc: 'Audience object', required: true
  param :message, type: :string, desc: 'Campaign message body', required: false
  param :instructions, type: :string, desc: 'Optional AI authoring instructions', required: false
  param :text_mode, type: :string, desc: 'Optional text mode: static, dynamic, or agent', required: false
  param :template_params, type: :object, desc: 'Optional template params object', required: false
  param :scheduled_at, type: :string, desc: 'Optional planned campaign send datetime used for WhatsApp official 24-hour policy', required: false

  def execute(inbox_id:, audience:, message: nil, instructions: nil, text_mode: nil, template_params: nil, scheduled_at: nil)
    ensure_account_administrator!

    inbox = account.inboxes.find(inbox_id)
    preview = ::Campaigns::PreviewService.new(
      account: account,
      inbox: inbox,
      audience: audience,
      message: message,
      instructions: instructions,
      text_mode: text_mode,
      template_params: template_params || {},
      scheduled_at: scheduled_at
    ).call

    formatted_payload(::Campaigns::ToolPayloadBuilder.preview_payload(preview))
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    account_administrator?
  end
end
