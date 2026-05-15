# frozen_string_literal: true

class Captain::Tools::Copilot::TestSendCampaignService < Captain::Tools::Copilot::CampaignAdminTool
  def self.name
    'test_send_campaign'
  end

  description 'Send a campaign test message to one explicit account contact without launching the campaign or creating campaign runs/deliveries'
  param :campaign_id, type: :integer, desc: 'Campaign display ID or database ID', required: true
  param :contact_id, type: :integer, desc: 'Explicit account contact ID that should receive the test message', required: true

  def execute(campaign_id:, contact_id:)
    ensure_account_administrator!

    campaign = find_campaign!(campaign_id)
    contact = contact!(contact_id)
    result = Campaigns::TestSendService.new(campaign: campaign, contact: contact, initiated_by: @user).perform

    formatted_payload(action: 'test_send_campaign', result: result, campaign: campaign_payload(campaign.reload, include_config: false))
  rescue StandardError => e
    tool_failure(e)
  end
end
