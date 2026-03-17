class Whatsapp::OneoffCampaignService
  pattr_initialize [:campaign!]

  def perform
    validate_campaign!
    # marks campaign completed so that other jobs won't pick it up
    campaign.completed!
    process_audience(extract_audience_labels)
  end

  private

  delegate :inbox, to: :campaign
  delegate :channel, to: :inbox

  def validate_campaign_type!
    raise "Invalid campaign #{campaign.id}" unless whatsapp_campaign? && campaign.one_off?
  end

  def whatsapp_campaign?
    campaign.inbox.inbox_type == 'Whatsapp'
  end

  def validate_campaign_status!
    raise 'Completed Campaign' if campaign.completed?
  end

  def validate_provider!
    raise 'WhatsApp Cloud provider required' if channel.provider != 'whatsapp_cloud'
  end

  def validate_feature_flag!
    raise 'WhatsApp campaigns feature not enabled' unless campaign.account.feature_enabled?(:whatsapp_campaign)
  end

  def validate_campaign!
    validate_campaign_type!
    validate_campaign_status!
    validate_provider!
    validate_feature_flag!
  end

  def extract_audience_labels
    audience_label_ids = campaign.audience.select { |audience| audience['type'] == 'Label' }.pluck('id')
    campaign.account.labels.where(id: audience_label_ids).pluck(:title)
  end

  def process_contact(contact)
    Rails.logger.info "Processing contact: #{contact.name} (#{contact.phone_number})"
    delivery = ensure_delivery(contact)

    if contact.phone_number.blank?
      delivery.mark_status!(status: :skipped, error_message: 'Contact has no phone number')
      Rails.logger.info "Skipping contact #{contact.name} - no phone number"
      return
    end

    if campaign.template_params.blank?
      delivery.mark_status!(status: :skipped, error_message: 'WhatsApp template params are missing')
      Rails.logger.error "Skipping contact #{contact.name} - no template_params found for WhatsApp campaign"
      return
    end

    send_whatsapp_template_message(delivery: delivery, to: contact.phone_number)
  end

  def process_audience(audience_labels)
    contacts = campaign.account.contacts.tagged_with(audience_labels, any: true)
    Rails.logger.info "Processing #{contacts.count} contacts for campaign #{campaign.id}"

    contacts.each { |contact| process_contact(contact) }

    Rails.logger.info "Campaign #{campaign.id} processing completed"
  end

  def send_whatsapp_template_message(delivery:, to:)
    processor = Whatsapp::TemplateProcessorService.new(
      channel: channel,
      template_params: campaign.template_params
    )

    name, namespace, lang_code, processed_parameters = processor.call

    if name.blank?
      delivery.mark_status!(status: :failed, error_message: 'Unable to resolve WhatsApp template')
      return
    end

    provider_message_id = channel.send_template(to, {
                                                  name: name,
                                                  namespace: namespace,
                                                  lang_code: lang_code,
                                                  parameters: processed_parameters
                                                }, nil)

    if provider_message_id.present?
      delivery.mark_status!(
        status: :submitted,
        provider_message_id: provider_message_id,
        metadata: { template_name: name, template_language: lang_code }
      )
    else
      delivery.mark_status!(status: :failed, error_message: 'WhatsApp provider did not return a message id')
    end

  rescue StandardError => e
    delivery.mark_status!(status: :failed, error_message: e.message)
    Rails.logger.error "Failed to send WhatsApp template message to #{to}: #{e.message}"
    Rails.logger.error "Backtrace: #{e.backtrace.first(5).join('\n')}"
    # continue processing remaining contacts
    nil
  end

  def ensure_delivery(contact)
    CampaignDelivery.track!(
      campaign: campaign,
      contact: contact,
      target_identifier: contact.phone_number,
      provider: channel.provider,
      status: :pending
    )
  end
end
