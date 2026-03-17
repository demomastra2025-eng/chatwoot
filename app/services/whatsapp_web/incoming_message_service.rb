class WhatsappWeb::IncomingMessageService < Whatsapp::IncomingMessageBaseService
  private

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
    remote_jid = params.dig(:key, :remoteJid).to_s
    remote_wa_id = remote_jid.split('@').first
    message_type = extract_message_type

    {
      contact: {
        wa_id: remote_wa_id,
        profile: {
          name: params[:pushName].presence || "+#{remote_wa_id}"
        }
      },
      message: {
        id: params.dig(:key, :id).to_s,
        type: message_type,
        context: reply_context
      }.merge(direction_payload(remote_wa_id))
        .merge(message_payload_for(message_type))
    }
  end

  def direction_payload(remote_wa_id)
    outgoing_echo ? { to: remote_wa_id } : { from: remote_wa_id }
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
