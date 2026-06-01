class Campaigns::OneoffRunner
  SERVICE_MAP = {
    'Twilio SMS' => ::Twilio::OneoffSmsCampaignService,
    'Sms' => ::Sms::OneoffSmsCampaignService,
    'Whatsapp' => ::Whatsapp::OneoffCampaignService,
    'Email' => ::Email::OneoffCampaignService,
    'WhatsApp Web' => ::WhatsappWeb::OneoffCampaignService,
    'Telegram' => ::Telegram::OneoffCampaignService,
    'Telegram Personal' => ::TelegramPersonal::OneoffCampaignService,
    'LinkedIn' => ::LinkedinPersonal::OneoffCampaignService,
    'VK' => ::VkCommunity::OneoffCampaignService,
    'LINE' => ::Line::OneoffCampaignService,
    'Facebook' => ::Facebook::OneoffCampaignService,
    'Instagram' => ::Instagram::OneoffCampaignService,
    'Tiktok' => ::Tiktok::OneoffCampaignService,
    'Twitter' => ::Twitter::OneoffCampaignService
  }.freeze

  pattr_initialize [:campaign!, { contact_ids: nil, retry_source_run: nil, allow_terminal_retry: false, restart_run: false, resume_run: false }]

  def perform
    service_class = SERVICE_MAP[campaign.inbox.inbox_type]
    raise "Invalid campaign #{campaign.id}" if service_class.blank?

    campaign_run = campaign.campaign_runs.create!(
      account: campaign.account,
      inbox: campaign.inbox,
      metadata: {
        inbox_type: campaign.inbox.inbox_type,
        campaign_type: campaign.campaign_type,
        retry_source_run_id: retry_source_run&.id,
        retry_contacts_count: Array.wrap(contact_ids).compact.size,
        restart_run: restart_run,
        resume_run: resume_run
      }.compact
    )

    service_class.new(
      campaign: campaign,
      campaign_run: campaign_run,
      contact_ids: contact_ids,
      allow_terminal_retry: allow_terminal_retry
    ).perform
    campaign_run
  rescue StandardError => e
    campaign_run&.fail!(e.message) unless campaign_run&.failed?
    raise
  end
end
