class WhatsappWeb::IncomingMessageService < Whatsapp::IncomingMessageBaseService
  private

  def after_message_persisted(message)
    super

    return if message.blank? || message.source_id.blank?

    pending_status = WhatsappWeb::PendingMessageStatusCache.new(
      inbox_id: inbox.id,
      source_id: message.source_id
    ).consume
    WhatsappWeb::ProviderPayloadNormalizer.apply_message_status!(message, pending_status) if pending_status.present?
    enqueue_media_attachment_backfill(message)
  end

  def create_message(message, source_id: nil)
    super.tap do |created_message|
      created_message.preserve_initial_pending_status = true if @preserve_initial_pending_status
      if group_message? && !outgoing_echo && group_sender_attributes.present?
        created_message.content_attributes = (created_message.content_attributes || {}).merge(
          'group_sender' => group_sender_attributes
        )
      end
    end
  end

  def conversation_params
    pending = inbox.channel.conversation_pending? && !group_message?
    @preserve_initial_pending_status = pending && !outgoing_echo
    base_params = super.merge(status: pending ? :pending : :open)
    return base_params unless group_message?

    base_params.merge(
      additional_attributes: (base_params[:additional_attributes] || {}).merge(
        'is_group' => true,
        'chat_type' => 'group',
        'chat_title' => group_subject
      ).compact
    )
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
        pushName: group_message? ? nil : params[:pushName],
        name: group_message? ? group_subject : nil
      },
      trust_payload_display_name: group_message? ? group_subject.present? : !outgoing_echo
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
    return group_display_name(remote_identity) if group_message?(remote_identity)
    return params[:pushName].presence if params[:pushName].present?
    return "+#{remote_identity.split('@').first}" if remote_identity.to_s.end_with?('@s.whatsapp.net')
    return remote_identity if remote_identity.to_s.include?('@')

    "+#{remote_identity}"
  end

  def group_display_name(remote_identity)
    group_subject.presence || @contact&.name.presence || "Group #{remote_identity.to_s.split('@').first}"
  end

  def group_message?(remote_identity = contact_remote_identity)
    remote_identity.to_s.end_with?('@g.us')
  end

  def group_subject
    params[:groupSubject].presence ||
      params.dig(:groupMetadata, :subject).presence ||
      params[:subject].presence ||
      params[:chatName].presence
  end

  def group_sender_attributes
    participant_jid = group_participant_jid
    phone_number = group_participant_phone(participant_jid)
    display_name = params[:pushName].to_s.strip.presence || phone_number || participant_jid.to_s.split('@').first.presence
    return if display_name.blank? && participant_jid.blank?

    {
      'id' => participant_jid || display_name,
      'name' => display_name,
      'phone_number' => phone_number
    }.compact
  end

  def group_participant_jid
    key = params[:key].to_h.deep_symbolize_keys
    (key[:participant] || key[:participantAlt] || params[:participant]).to_s.presence
  end

  def group_participant_phone(participant_jid)
    return unless participant_jid.to_s.end_with?('@s.whatsapp.net')

    digits = participant_jid.to_s.split('@').first.to_s.split(':').first.to_s.gsub(/\D/, '')
    "+#{digits}" if digits.present?
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
    when 'reaction'
      reaction_payload
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
    return 'reaction' if message[:reactionMessage].present?

    'unsupported'

  end

  def reaction_payload
    payload = params.dig(:message, :reactionMessage).to_h.deep_symbolize_keys
    raw_timestamp = payload[:senderTimestampMs] || params[:messageTimestamp]

    {
      timestamp: raw_timestamp&.to_s,
      reaction: {
        message_id: payload.dig(:key, :id).to_s,
        emoji: payload[:text].to_s
      }
    }.compact
  end

  def extracted_text_body
    message = params[:message].to_h.deep_symbolize_keys

    message[:conversation].presence ||
      message.dig(:extendedTextMessage, :text).presence ||
      ''
  end

  def download_attachment_file(attachment_payload)
    @pending_media_attachment_backfill = false
    result = WhatsappWeb::MediaAttachmentResolver.new(
      channel: inbox.channel,
      record: params,
      source_id: messages_data.first[:id]
    ).resolve(attachment_payload)

    @pending_media_attachment_backfill = result.pending_backfill
    result.file
  end

  def enqueue_media_attachment_backfill(message)
    return unless @pending_media_attachment_backfill
    return if message.attachments.any?

    Channels::WhatsappWeb::MediaAttachmentBackfillJob.set(wait: 5.seconds).perform_later(
      inbox.channel.id,
      message.source_id,
      params.to_h.deep_stringify_keys,
      1
    )
  end
end
