# Mostly modeled after the intial implementation of the service based on 360 Dialog
# https://docs.360dialog.com/whatsapp-api/whatsapp-api/media
# https://developers.facebook.com/docs/whatsapp/api/media/
class Whatsapp::IncomingMessageBaseService
  include ::Whatsapp::IncomingMessageServiceHelpers

  pattr_initialize [:inbox!, :params!, :outgoing_echo]

  def perform
    processed_params

    if processed_params.try(:[], :statuses).present?
      process_statuses
    elsif messages_data.present?
      process_messages
    end
  end

  # Returns messages array for both regular messages and echo events
  def messages_data
    @processed_params&.dig(:messages) || @processed_params&.dig(:message_echoes)
  end

  private

  def process_messages
    message = messages_data.first
    return if mutation_service(message).perform
    return if ignore_unsupported_message?(message)

    # Multiple webhook events can be received for the same message due to
    # misconfigurations in the Meta business manager account.
    # We use an atomic Redis SET NX to prevent concurrent workers from both
    # processing the same message simultaneously.
    if find_message_by_source_id(message[:id])
      process_history_media_follow_up
      replay_pending_message_mutations(@message)
      return
    end

    with_message_dedup_lock { process_new_message }
  end

  def mutation_service(message)
    Whatsapp::IncomingMessageMutationService.new(inbox: inbox, message: message, outgoing_echo: outgoing_echo)
  end

  def ignore_unsupported_message?(message)
    return false unless unprocessable_message_type?(message)

    Rails.logger.info("[WHATSAPP] Ignored unsupported message type=#{message[:type]} event_id=#{message[:id]}")
    true
  end

  def with_message_dedup_lock
    dedup_lock = message_dedup_lock
    return unless dedup_lock&.acquire!

    begin
      yield
    rescue ActiveRecord::RecordNotUnique
      @message = Message.find_by(source_id: messages_data.first[:id].to_s, inbox_id: inbox.id)
      after_message_persisted(@message) if @message.present?
    ensure
      dedup_lock.release!
    end
  end

  def process_new_message
    set_contact
    return unless @contact
    return if @contact.blocked? && !outgoing_echo

    process_in_reply_to(messages_data.first)

    ActiveRecord::Base.transaction do
      set_conversation
      create_messages
    end
  end

  def process_statuses
    status_payload = @processed_params[:statuses].first
    find_message_by_source_id(status_payload[:id])
    update_whatsapp_identifiers_from_status(status_payload) if @message.present?
    update_message_with_status(@message, status_payload) if @message.present?
    update_campaign_delivery_with_status(status_payload)
  rescue ArgumentError => e
    Rails.logger.error "Error while processing whatsapp status update #{e.message}"
  end

  def update_message_with_status(message, status)
    message.status = status[:status]
    if status[:status] == 'failed' && status[:errors].present?
      error = status[:errors]&.first
      message.external_error = "#{error[:code]}: #{error[:title]}"
    end
    message.save!
  end

  def update_campaign_delivery_with_status(status)
    delivery = CampaignDelivery.find_by(provider_message_id: status[:id], inbox_id: inbox.id)
    return if delivery.blank?

    error_message = if status[:status] == 'failed' && status[:errors].present?
                      error = status[:errors].first
                      "#{error[:code]}: #{error[:title]}"
                    end

    delivery.mark_status!(status: status[:status], error_message: error_message)
  end

  def create_messages
    message = messages_data.first
    log_error(message) && return if error_webhook_event?(message)

    message_type == 'contacts' ? create_contact_messages(message) : create_regular_message(message)
  end

  def create_contact_messages(message)
    contacts = Array(message['contacts'])
    contacts.each_with_index do |contact, index|
      contact_message = contact.to_h.with_indifferent_access.merge(timestamp: message[:timestamp])
      create_message(contact_message, source_id: contact_message_source_id(message, index, contacts.size))
      attach_contact(contact)
      @message.save!
      after_message_persisted(@message)
    end
  end

  def create_regular_message(message)
    create_message(message, source_id: message[:id])
    attach_files
    attach_location if message_type == 'location'
    @message.save!
    after_message_persisted(@message)
  end

  def process_history_media_follow_up
    return unless history_media_placeholder?(@message)
    return unless media_follow_up?

    dedup_lock = message_dedup_lock
    return unless dedup_lock&.acquire!

    begin
      upgrade_history_media_placeholder
    ensure
      dedup_lock.release!
    end
  end

  def upgrade_history_media_placeholder
    @message.reload
    return unless history_media_placeholder?(@message)
    return unless attach_history_media

    attachment_payload = messages_data.first[message_type.to_sym].to_h.with_indifferent_access
    @message.content = attachment_payload[:caption]
    @message.content_attributes = @message.content_attributes.to_h.merge(
      'whatsapp_message_type' => message_type,
      'whatsapp_history_media_follow_up' => true
    )
    @message.save!
  end

  def attach_history_media
    previous_attachment_count = @message.attachments.size
    attach_files
    @message.attachments.size > previous_attachment_count
  end

  def history_media_placeholder?(message)
    message.content_attributes.to_h['whatsapp_history_original_type'] == 'media_placeholder' && message.attachments.empty?
  end

  def media_follow_up?
    %w[audio document image sticker video].include?(message_type) && messages_data.first[message_type.to_sym].present?
  end

  def set_contact
    if outgoing_echo
      set_contact_from_echo
    else
      set_contact_from_message
    end
  end

  def set_contact_from_echo
    contact_inbox = Whatsapp::ContactIdentityResolver.new(
      inbox: inbox,
      message: messages_data.first,
      outgoing_echo: true
    ).perform

    return if contact_inbox.blank?

    @contact_inbox = contact_inbox
    @contact = contact_inbox.contact
  end

  def set_contact_from_message
    contact_params = @processed_params[:contacts]&.first
    return if contact_params.blank?

    contact_inbox = Whatsapp::ContactIdentityResolver.new(
      inbox: inbox,
      message: messages_data.first,
      contact_params: contact_params
    ).perform

    return if contact_inbox.blank?

    @contact_inbox = contact_inbox
    @contact = contact_inbox.contact

    # Update existing contact name if ProfileName is available and current name is just phone number
    update_contact_with_profile_name(contact_params)
  end

  def set_conversation
    @conversation = conversation_from_reply_context || existing_contact_conversation
    return if @conversation

    @conversation = ::Conversation.create!(conversation_params)
  end

  def attach_files
    return if %w[text button interactive location contacts order unsupported].include?(message_type)

    attachment_payload = messages_data.first[message_type.to_sym]
    @message.content ||= attachment_payload[:caption]

    attachment_file = download_attachment_file(attachment_payload)
    return if attachment_file.blank?

    @message.attachments.new(
      account_id: @message.account_id,
      file_type: file_content_type(message_type),
      file: {
        io: attachment_file,
        filename: attachment_filename(attachment_payload, attachment_file),
        content_type: attachment_content_type(attachment_payload, attachment_file)
      }
    ).skip_storage_limit_validation!
  end

  def attachment_filename(attachment_payload, attachment_file)
    attachment_payload_value(attachment_payload, :filename).presence || attachment_file.original_filename
  end

  def attachment_content_type(attachment_payload, attachment_file)
    attachment_payload_value(attachment_payload, :mime_type).presence || attachment_file.content_type
  end

  def attachment_payload_value(attachment_payload, key)
    attachment_payload[key] || attachment_payload[key.to_s]
  end

  def attach_location
    location = messages_data.first['location']
    location_name = location['name'] ? "#{location['name']}, #{location['address']}" : ''
    @message.attachments.new(
      account_id: @message.account_id,
      file_type: file_content_type(message_type),
      coordinates_lat: location['latitude'],
      coordinates_long: location['longitude'],
      fallback_title: location_name,
      external_url: location['url']
    ).skip_storage_limit_validation!
  end

  def create_message(message, source_id: nil)
    content_attrs = outgoing_echo ? { external_echo: true } : {}
    content_attrs[:in_reply_to_external_id] = @in_reply_to_external_id if @in_reply_to_external_id.present?
    content_attrs.merge!(message_content_attributes(message))
    content_attrs.merge!(provider_timing_attributes(message))

    message_attributes = {
      content: message_content(message),
      account_id: @inbox.account_id,
      inbox_id: @inbox.id,
      message_type: outgoing_echo ? :outgoing : :incoming,
      # Set status to :delivered for echo messages to prevent SendReplyJob from trying to send them
      status: outgoing_echo ? :delivered : :sent,
      sender: outgoing_echo ? nil : @contact,
      source_id: (source_id || message[:id]).to_s,
      content_attributes: content_attrs
    }
    provider_created_at = provider_message_time(message)
    message_attributes[:created_at] = provider_created_at if provider_created_at.present?
    @message = @conversation.messages.build(message_attributes)
  end

  def contact_message_source_id(message, index, contacts_count)
    base_source_id = message[:id].to_s
    return base_source_id if contacts_count <= 1

    "#{base_source_id}:contact:#{index}"
  end

  def attach_contact(contact)
    phones = contact[:phones]
    phones = [{ phone: 'Phone number is not available' }] if phones.blank?

    name_info = contact['name'] || {}
    contact_meta = {
      firstName: name_info['first_name'],
      lastName: name_info['last_name']
    }.compact

    phones.each do |phone|
      @message.attachments.new(
        account_id: @message.account_id,
        file_type: file_content_type(message_type),
        fallback_title: phone[:phone].to_s,
        meta: contact_meta
      ).skip_storage_limit_validation!
    end
  end

  def update_contact_with_profile_name(contact_params)
    profile_name = contact_params.dig(:profile, :name)
    return if profile_name.blank?
    return if @contact.name == profile_name

    # Only update if current name exactly matches the phone number or formatted phone number
    return unless contact_name_matches_phone_number?

    @contact.update!(name: profile_name)
  end

  def contact_name_matches_phone_number?
    phone_number = Whatsapp::ContactIdentityResolver.phone_number_for(messages_data.first[:from])
    return false if phone_number.blank?

    formatted_phone_number = TelephoneNumber.parse(phone_number).international_number
    @contact.name == phone_number || @contact.name == formatted_phone_number
  end

  def conversation_from_reply_context
    return if @in_reply_to_external_id.blank?

    Message.find_by(source_id: @in_reply_to_external_id, inbox_id: @inbox.id)&.conversation
  end

  def existing_contact_conversation
    return contact_identity_conversations.last if @inbox.lock_to_single_conversation

    contact_identity_conversations.where.not(status: :resolved).last || latest_campaign_conversation
  end

  def latest_campaign_conversation
    latest_conversation = contact_identity_conversations.last
    return unless latest_conversation&.resolved?
    return if latest_conversation.campaign_id.blank?

    latest_conversation
  end

  def contact_identity_conversations
    @contact_identity_conversations ||= @inbox.conversations.where(
      contact_inbox_id: @contact.contact_inboxes.where(inbox_id: @inbox.id).select(:id)
    )
  end

  def after_message_persisted(message)
    record_meta_ad_referral(message)
    replay_pending_message_mutations(message)
  end

  def replay_pending_message_mutations(message)
    Whatsapp::IncomingMessageMutationService.replay_pending_for(message)
  end

  def provider_timing_attributes(message)
    attributes = { 'whatsapp_ingested_at' => Time.current.iso8601(6) }
    provider_created_at = provider_message_time(message)
    attributes['external_created_at'] = provider_created_at.iso8601 if provider_created_at.present?
    attributes
  end

  def provider_message_time(message)
    Whatsapp::ProviderTimestamp.time(message[:timestamp])
  end

  def record_meta_ad_referral(message)
    meta_referral = message&.content_attributes.to_h.with_indifferent_access[:meta_referral]
    return if meta_referral.blank?

    Meta::AdReferralRecorder.new(message: message, payload: meta_referral).perform
  rescue StandardError => e
    Rails.logger.warn("[MetaAdReferral] WhatsApp referral persistence failed: #{e.class}: #{e.message}")
  end
end
