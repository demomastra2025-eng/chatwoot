class Whatsapp::OneoffCampaignService < Campaigns::OneoffBaseService
  private

  def supported_inbox_types
    'Whatsapp'
  end

  def delivery_provider
    channel.provider
  end

  def missing_target_error_message
    'Contact has no phone number'
  end

  def validate_campaign_specific!
    raise 'WhatsApp Cloud provider required' if channel.provider != 'whatsapp_cloud'
    raise 'WhatsApp campaigns feature not enabled' unless campaign.account.feature_enabled?(:whatsapp_campaign)
  end

  def skip_contact_reason(_contact)
    return if campaign.template_params.present?

    'WhatsApp template params are missing'
  end

  def log_skip(contact, reason)
    return unless reason == 'WhatsApp template params are missing'

    Rails.logger.error "Skipping contact #{contact.name} - no template_params found for WhatsApp campaign"
  end

  def perform_delivery(contact:, delivery:, target_identifier:)
    processed_template_params = process_liquid_template_params(contact)
    if processed_template_params.nil?
      delivery.mark_status!(status: :skipped, error_message: 'WhatsApp template variables resolved to blank values')
      return delivery
    end

    message = Campaigns::OneoffConversationBuilder.new(
      campaign: campaign,
      contact: contact,
      source_id: target_identifier,
      campaign_run: current_campaign_run,
      template_params: processed_template_params
    ).perform
    delivery.mark_status!(status: :pending, metadata: { message_id: message.id })
    delivery
  end

  def process_liquid_template_params(contact)
    liquid_processor = Whatsapp::LiquidTemplateProcessorService.new(campaign: campaign, contact: contact)
    processed_template_params = liquid_processor.process_template_params(campaign.template_params)

    Rails.logger.info "Skipping contact #{contact.name} - liquid variables resolved to blank values" if processed_template_params.nil?

    processed_template_params
  end

  def log_delivery_failure(contact, error)
    Rails.logger.error "Failed to create WhatsApp campaign message for #{contact.phone_number}: #{error.message}"
    Rails.logger.error "Backtrace: #{error.backtrace.first(5).join('\n')}"
  end
end
