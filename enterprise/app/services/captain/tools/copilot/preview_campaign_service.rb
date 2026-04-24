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

  def execute(inbox_id:, audience:, message: nil, instructions: nil, text_mode: nil, template_params: nil)
    inbox = account.inboxes.find(inbox_id)
    preview = ::Campaigns::PreviewService.new(
      account: account,
      inbox: inbox,
      audience: audience,
      message: message,
      instructions: instructions,
      text_mode: text_mode,
      template_params: template_params || {}
    ).call

    formatted_payload(preview)
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    account_administrator?
  end
end
