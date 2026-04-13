class TelegramPersonal::IncomingMessageService
  include ::FileTypeHelper

  ATTACHMENT_PLACEHOLDER = '[Attachment]'.freeze

  pattr_initialize [:inbox!, :params!]

  def perform
    return unless private_chat?
    return if inbox.messages.exists?(source_id: storage_source_id)
    return unless lock_message_source_id!

    set_contact
    return if @contact.blank?

    set_conversation
    return if reconcile_outgoing_echo!

    build_message
    attach_files
    attach_location
    attach_contact
    @message.save!
  end

  private

  def private_chat?
    params[:chat_type].to_s.in?(%w[private user private_chat]) || params[:chat_type].blank?
  end

  def set_contact
    @contact_inbox = TelegramPersonal::ContactSyncService.new(
      inbox: inbox,
      params: params
    ).perform
    @contact = @contact_inbox&.contact
  end

  def set_conversation
    @conversation = if inbox.lock_to_single_conversation
                      @contact_inbox.conversations.last
                    else
                      @contact_inbox.conversations.where.not(status: :resolved).last
                    end
    if @conversation.present?
      merged_attributes = (@conversation.additional_attributes || {}).merge(conversation_additional_attributes)
      @conversation.update!(additional_attributes: merged_attributes) if merged_attributes != @conversation.additional_attributes
      return
    end

    @conversation = ::Conversation.create!(
      account_id: inbox.account_id,
      inbox_id: inbox.id,
      contact_id: @contact.id,
      contact_inbox_id: @contact_inbox.id,
      additional_attributes: conversation_additional_attributes
    )
  end

  def build_message
    message_attributes = {
      content: params[:text].presence || params[:caption].presence || '',
      account_id: inbox.account_id,
      inbox_id: inbox.id,
      message_type: outgoing_echo? ? :outgoing : :incoming,
      status: outgoing_echo? ? :delivered : :sent,
      sender: outgoing_echo? ? nil : @contact,
      source_id: storage_source_id,
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

    message = matching_outgoing_message
    return false if message.blank?

    attrs = {
      source_id: storage_source_id,
      status: message.read? ? :read : :delivered,
      content_attributes: (message.content_attributes || {}).merge(reconciled_message_content_attributes)
    }
    attrs[:content] = echo_content if message.content.blank? && echo_content.present?

    message.update!(attrs)
    @message = message
    true
  end

  def attach_files
    Array.wrap(params[:attachments]).each do |attachment|
      next if attachment[:url].blank?

      attach_single_file(attachment)
    end

    mark_media_only_message_unavailable
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
    track_unavailable_attachment(attachment, e)
    Rails.logger.info("[TELEGRAM PERSONAL] Attachment download failed for #{storage_source_id}: #{e.class}: #{e.message}")
    nil
  end

  def track_unavailable_attachment(attachment, error)
    @unavailable_attachments ||= []
    @unavailable_attachments << {
      kind: attachment[:kind],
      filename: attachment[:filename],
      content_type: attachment[:content_type],
      url: attachment[:url],
      error: error.class.name
    }.compact

    @message.content_attributes = @message.content_attributes.to_h.merge(
      'telegram_unavailable_attachments' => @unavailable_attachments
    )
  end

  def mark_media_only_message_unavailable
    return if @unavailable_attachments.blank?
    return if @message.content.present?
    return if @message.attachments.present?

    @message.content = ATTACHMENT_PLACEHOLDER
  end

  def attach_location
    location = params[:location].to_h
    return if location.blank?

    @message.attachments.new(
      account_id: @message.account_id,
      file_type: :location,
      fallback_title: location[:name].presence || '',
      coordinates_lat: location[:latitude],
      coordinates_long: location[:longitude]
    ).skip_storage_limit_validation!
  end

  def attach_contact
    contact = params[:contact].to_h
    return if contact.blank?

    @message.attachments.new(
      account_id: @message.account_id,
      file_type: :contact,
      fallback_title: contact[:phone_number].to_s,
      meta: {
        first_name: contact[:first_name],
        last_name: contact[:last_name]
      }.compact
    ).skip_storage_limit_validation!
  end

  def outgoing_echo?
    ActiveModel::Type::Boolean.new.cast(params[:outgoing_echo])
  end

  def external_message_id
    params[:message_id].to_s
  end

  def storage_source_id
    telegram_message_ids.first.presence || external_message_id
  end

  def matching_outgoing_message
    @conversation.messages.outgoing
                 .where(source_id: nil)
                 .where('created_at >= ?', 10.minutes.ago)
                 .reorder(created_at: :desc)
                 .detect { |message| outgoing_message_matches_echo?(message) }
  end

  def outgoing_message_matches_echo?(message)
    message.outgoing_content.to_s.strip == echo_content.to_s.strip &&
      message.content_attributes.to_h['in_reply_to_external_id'].to_s == params[:reply_to_message_id].to_s &&
      message.attachments.size == expected_attachment_count
  end

  def echo_content
    params[:text].presence || params[:caption].presence || ''
  end

  def expected_attachment_count
    Array.wrap(params[:attachments]).size + (params[:location].present? ? 1 : 0) + (params[:contact].present? ? 1 : 0)
  end

  def lock_message_source_id!
    return false if dedup_source_id.blank?

    TelegramPersonal::MessageDedupLock.new(
      inbox_id: inbox.id,
      source_id: dedup_source_id
    ).acquire!
  end

  def dedup_source_id
    return "album:#{params[:grouped_id]}" if params[:grouped_id].present?

    storage_source_id
  end

  def telegram_message_ids
    Array.wrap(params[:telegram_message_ids]).map(&:to_s).reject(&:blank?).presence || [external_message_id].reject(&:blank?)
  end

  def conversation_additional_attributes
    {
      chat_id: params[:chat_id],
      peer_user_id: peer_user_id,
      username: params[:username]
    }.compact
  end

  def message_content_attributes
    {}.tap do |attrs|
      attrs[:external_echo] = true if outgoing_echo?
      attrs[:voice_note] = true if voice_note?
      attrs[:external_created_at] = provider_message_time.iso8601 if provider_message_time.present?
      attrs[:imported_history] = true if imported_history?
      attrs[:in_reply_to_external_id] = params[:reply_to_message_id].to_s if params[:reply_to_message_id].present?
      attrs[:telegram_message_ids] = telegram_message_ids if telegram_message_ids.many?
      attrs[:grouped_id] = params[:grouped_id].to_s if params[:grouped_id].present?
      attrs[:telegram_reactions] = params[:reactions].to_h if params[:reactions].present?
      attrs[:telegram_forwarded_from] = params[:forwarded_from].to_h if params[:forwarded_from].present?
    end
  end

  def reconciled_message_content_attributes
    message_content_attributes.except(:imported_history)
  end

  def normalized_file_type(kind, content_type)
    return :image if kind.to_s == 'photo'
    return :audio if %w[audio voice].include?(kind.to_s)
    return :video if kind.to_s == 'video'
    return :file if %w[document sticker].include?(kind.to_s)

    file_type(content_type)
  end

  def imported_history?
    ActiveModel::Type::Boolean.new.cast(params[:imported_history])
  end

  def provider_message_time
    return @provider_message_time if defined?(@provider_message_time)

    value = params[:message_created_at].presence || params[:external_created_at].presence
    @provider_message_time = if value.present?
                               value.respond_to?(:in_time_zone) ? value.in_time_zone : Time.zone.parse(value.to_s)
                             end
  rescue ArgumentError
    @provider_message_time = nil
  end

  def peer_user_id
    params[:peer_user_id] || params[:sender_id] || params[:chat_id]
  end

  def voice_note?
    Array.wrap(params[:attachments]).any? do |attachment|
      attachment[:kind].to_s == 'voice'
    end
  end
end
