class LinkedinPersonal::IncomingMessageService
  include ::FileTypeHelper

  ATTACHMENT_PLACEHOLDER = '[Attachment]'.freeze

  pattr_initialize [:inbox!, :params!]

  def perform
    return if message_id.blank?
    return if inbox.messages.exists?(source_id: message_id)
    return unless lock_message_source_id!

    set_contact
    return if @contact.blank?

    set_conversation
    return if reconcile_outgoing_echo!

    build_message
    attach_files
    @message.save!
  rescue ActiveRecord::RecordNotUnique
    nil
  end

  private

  def set_contact
    @contact_inbox = LinkedinPersonal::ContactSyncService.new(inbox: inbox, params: contact_payload).perform
    @contact = @contact_inbox&.contact
  end

  def set_conversation
    @conversation = LinkedinPersonal::ConversationSyncService.new(
      inbox: inbox,
      contact_inbox: @contact_inbox,
      activity_at: provider_message_time || Time.current,
      additional_attributes: conversation_additional_attributes
    ).perform
  end

  def build_message
    message_attributes = {
      content: params[:text].presence || params[:caption].presence || '',
      account_id: inbox.account_id,
      inbox_id: inbox.id,
      message_type: outgoing_echo? ? :outgoing : :incoming,
      status: outgoing_echo? ? :delivered : :sent,
      sender: outgoing_echo? ? nil : @contact,
      source_id: message_id,
      content_attributes: message_content_attributes
    }
    if provider_message_time.present?
      message_attributes[:created_at] = provider_message_time
      message_attributes[:updated_at] = provider_message_time
    end

    @message = @conversation.messages.build(message_attributes)
    @message.skip_runtime_events = true if imported_history? || outgoing_echo?
  end

  def reconcile_outgoing_echo!
    return false unless outgoing_echo?

    message = @conversation.messages.outgoing
                           .where(source_id: nil)
                           .where('created_at >= ?', 10.minutes.ago)
                           .reorder(created_at: :desc)
                           .detect { |candidate| outgoing_message_matches_echo?(candidate) }
    return false if message.blank?

    message.update!(
      source_id: message_id,
      status: message.read? ? :read : :delivered,
      content_attributes: (message.content_attributes || {}).merge(message_content_attributes.except(:imported_history))
    )
    @message = message
    true
  end

  def attach_files
    Array.wrap(params[:attachments]).each do |attachment|
      next if attachment[:url].blank?

      attach_single_file(attachment)
    end

    return if @unavailable_attachments.blank? || @message.content.present? || @message.attachments.present?

    @message.content = ATTACHMENT_PLACEHOLDER
  end

  def attach_single_file(attachment)
    attachment_file = Down.download(attachment[:url])
    @message.attachments.new(
      account_id: @message.account_id,
      file_type: normalized_file_type(attachment[:kind], attachment_file.content_type),
      file: {
        io: attachment_file,
        filename: attachment[:filename].presence || attachment_file.original_filename,
        content_type: attachment[:content_type].presence || attachment_file.content_type
      }
    ).skip_storage_limit_validation!
  rescue StandardError => e
    @unavailable_attachments ||= []
    @unavailable_attachments << attachment.to_h.slice(:kind, :filename, :content_type, :url).merge(error: e.class.name)
    @message.content_attributes = @message.content_attributes.to_h.merge(
      'linkedin_unavailable_attachments' => @unavailable_attachments
    )
    Rails.logger.info("[LINKEDIN PERSONAL] Attachment download failed for #{message_id}: #{e.class}: #{e.message}")
  end

  def outgoing_message_matches_echo?(message)
    message.outgoing_content.to_s.strip == params[:text].to_s.strip &&
      message.attachments.size == Array.wrap(params[:attachments]).size
  end

  def contact_payload
    (params[:sender] || {}).to_h.deep_symbolize_keys.reverse_merge(
      profile_urn: peer_profile_urn,
      last_message_at: provider_message_time&.iso8601
    )
  end

  def conversation_additional_attributes
    {
      linkedin_conversation_urn: conversation_urn,
      conversation_urn: conversation_urn,
      peer_profile_urn: peer_profile_urn
    }.compact
  end

  def message_content_attributes
    {}.tap do |attrs|
      attrs[:external_echo] = true if outgoing_echo?
      attrs[:external_created_at] = provider_message_time.iso8601 if provider_message_time.present?
      attrs[:imported_history] = true if imported_history?
      attrs[:in_reply_to_external_id] = params[:reply_to_message_id].to_s if params[:reply_to_message_id].present?
      attrs[:linkedin_conversation_urn] = conversation_urn if conversation_urn.present?
      attrs[:linkedin_reactions] = params[:reactions].to_h if params[:reactions].present?
    end
  end

  def normalized_file_type(kind, content_type)
    return :image if kind.to_s == 'image'
    return :audio if kind.to_s == 'audio'
    return :video if kind.to_s == 'video'
    return :file if kind.to_s == 'file'

    file_type(content_type)
  end

  def lock_message_source_id!
    LinkedinPersonal::MessageDedupLock.new(inbox_id: inbox.id, source_id: message_id).acquire!
  end

  def imported_history?
    ActiveModel::Type::Boolean.new.cast(params[:imported_history])
  end

  def outgoing_echo?
    ActiveModel::Type::Boolean.new.cast(params[:outgoing_echo])
  end

  def message_id
    params[:message_id].to_s.presence
  end

  def conversation_urn
    params[:conversation_urn].to_s.presence
  end

  def peer_profile_urn
    params[:peer_profile_urn].presence || params.dig(:sender, :profile_urn).presence || params[:sender_urn].presence
  end

  def provider_message_time
    return @provider_message_time if defined?(@provider_message_time)

    value = params[:message_created_at].presence || params[:external_created_at].presence
    @provider_message_time = value.present? ? Time.zone.parse(value.to_s) : nil
  rescue ArgumentError, TypeError
    @provider_message_time = nil
  end
end
