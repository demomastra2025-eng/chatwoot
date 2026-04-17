class WhatsappWeb::IncomingMessageService < Whatsapp::IncomingMessageBaseService
  private

  def after_message_persisted(message)
    super

    return if message.blank? || message.source_id.blank?

    pending_status = WhatsappWeb::PendingMessageStatusCache.new(
      inbox_id: inbox.id,
      source_id: message.source_id
    ).consume
    return if pending_status.blank?

    WhatsappWeb::ProviderPayloadNormalizer.apply_message_status!(message, pending_status)
  end

  def conversation_params
    super.merge(status: inbox.channel.conversation_pending? ? :pending : :open)
  end

  def processed_params
    @processed_params ||= begin
      transformed = transformed_message
      {
        contacts: [transformed[:contact]],
        messages: [transformed[:message]]
      }.with_indifferent_access
    end
  end

  def transformed_message
    remote_identity = contact_remote_identity
    message_type = extract_message_type

    {
      contact: {
        wa_id: remote_identity,
        profile: {
          name: contact_display_name(remote_identity)
        }
      },
      message: {
        id: params.dig(:key, :id).to_s,
        type: message_type,
        context: reply_context
      }.merge(direction_payload(remote_identity))
        .merge(message_payload_for(message_type))
    }
  end

  def direction_payload(remote_identity)
    outgoing_echo ? { to: remote_identity } : { from: remote_identity }
  end

  def set_contact_from_echo
    set_contact_from_whatsapp_web_identity
  end

  def set_contact_from_message
    set_contact_from_whatsapp_web_identity
  end

  def existing_contact_conversation
    current_conversation = super
    return if @contact.blank?

    latest_contact_conversation = inbox.conversations.where(contact_id: @contact.id).order(last_activity_at: :desc, id: :desc).first
    return latest_contact_conversation if current_conversation.blank?
    return current_conversation if latest_contact_conversation.blank?

    [current_conversation, latest_contact_conversation].max_by do |conversation|
      [conversation.last_activity_at, conversation.id]
    end
  end

  def set_contact_from_whatsapp_web_identity
    contact_inbox = WhatsappWeb::ContactSyncService.new(
      channel: inbox.channel,
      contact_payload: {
        remoteJid: params.dig(:key, :remoteJid),
        remoteJidAlt: params.dig(:key, :remoteJidAlt),
        remoteLid: params.dig(:key, :remoteLid),
        pushName: params[:pushName]
      }
    ).perform
    return if contact_inbox.blank?

    @contact_inbox = contact_inbox
    @contact = contact_inbox.contact
  end

  def contact_remote_identity
    key = params[:key].to_h.deep_symbolize_keys

    WhatsappWeb::ProviderPayloadNormalizer.canonical_remote_jid(
      key[:remoteJid],
      key[:remoteJidAlt],
      key[:remoteLid]
    ).presence || key[:remoteJid].to_s.presence || key[:remoteJidAlt].to_s.presence || key[:remoteLid].to_s
  end

  def contact_display_name(remote_identity)
    return params[:pushName].presence if params[:pushName].present?
    return "+#{remote_identity.split('@').first}" if remote_identity.to_s.end_with?('@s.whatsapp.net')
    return remote_identity if remote_identity.to_s.include?('@')

    "+#{remote_identity}"
  end

  def message_payload_for(message_type)
    case message_type
    when 'text'
      {
        text: {
          body: extracted_text_body
        }
      }
    when 'image', 'video', 'audio', 'document', 'sticker'
      {
        message_type.to_sym => attachment_payload_for(message_type)
      }
    when 'location'
      {
        location: location_payload
      }
    else
      {
        text: {
          body: ''
        }
      }
    end
  end

  def attachment_payload_for(message_type)
    message_key = attachment_message_key(message_type)
    payload = attachment_message_payload(message_key)

    {
      caption: payload[:caption],
      mimetype: payload[:mimetype],
      fileName: payload[:fileName],
      base64: params.dig(:message, :base64),
      mediaUrl: payload[:mediaUrl] || payload[:url]
    }.compact
  end

  def attachment_message_key(message_type)
    {
      'image' => :imageMessage,
      'video' => :videoMessage,
      'audio' => :audioMessage,
      'document' => :documentMessage,
      'sticker' => :stickerMessage
    }.fetch(message_type)
  end

  def attachment_message_payload(message_key)
    message = params[:message].to_h.deep_symbolize_keys

    message[message_key].to_h.deep_symbolize_keys.presence ||
      message.dig(:documentWithCaptionMessage, :message, message_key).to_h.deep_symbolize_keys
  end

  def location_payload
    payload = params.dig(:message, :locationMessage).to_h.deep_symbolize_keys

    {
      latitude: payload[:degreesLatitude] || payload[:latitude],
      longitude: payload[:degreesLongitude] || payload[:longitude],
      name: payload[:name],
      address: payload[:address],
      url: payload[:url]
    }.compact
  end

  def reply_context
    stanza_id = extract_stanza_id
    return {} if stanza_id.blank?

    { id: stanza_id }
  end

  def extract_stanza_id
    message = params[:message].to_h.deep_symbolize_keys

    [
      params.dig(:contextInfo, :stanzaId),
      message.dig(:contextInfo, :stanzaId),
      message.dig(:extendedTextMessage, :contextInfo, :stanzaId),
      message.dig(:imageMessage, :contextInfo, :stanzaId),
      message.dig(:videoMessage, :contextInfo, :stanzaId),
      message.dig(:audioMessage, :contextInfo, :stanzaId),
      message.dig(:documentMessage, :contextInfo, :stanzaId),
      message.dig(:documentWithCaptionMessage, :message, :documentMessage, :contextInfo, :stanzaId),
      message.dig(:stickerMessage, :contextInfo, :stanzaId)
    ].compact_blank.first
  end

  def extract_message_type
    message = params[:message].to_h.deep_symbolize_keys
    return 'text' if message[:conversation].present? || message[:extendedTextMessage].present?
    return 'image' if message[:imageMessage].present?
    return 'video' if message[:videoMessage].present?
    return 'audio' if message[:audioMessage].present?
    return 'document' if message[:documentMessage].present? ||
                         message.dig(:documentWithCaptionMessage, :message, :documentMessage).present?
    return 'sticker' if message[:stickerMessage].present?
    return 'location' if message[:locationMessage].present?

    'unsupported'
  end

  def extracted_text_body
    message = params[:message].to_h.deep_symbolize_keys

    message[:conversation].presence ||
      message.dig(:extendedTextMessage, :text).presence ||
      ''
  end

  def download_attachment_file(attachment_payload)
    return file_from_base64(attachment_payload) if attachment_payload[:base64].present?
    return Down.download(attachment_payload[:mediaUrl]) if attachment_payload[:mediaUrl].present?

    nil
  end

  def file_from_base64(attachment_payload)
    content_type = attachment_payload[:mimetype].presence || 'application/octet-stream'
    filename = attachment_payload[:fileName].presence || "whatsapp-web-#{SecureRandom.hex(8)}"
    tempfile = Tempfile.new(['whatsapp-web', File.extname(filename)])
    tempfile.binmode
    tempfile.write(Base64.decode64(attachment_payload[:base64]))
    tempfile.rewind
    tempfile.define_singleton_method(:original_filename) { filename }
    tempfile.define_singleton_method(:content_type) { content_type }
    tempfile
  end
end
