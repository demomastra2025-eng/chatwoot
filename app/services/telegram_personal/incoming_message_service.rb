class TelegramPersonal::IncomingMessageService
  include ::FileTypeHelper

  ATTACHMENT_PLACEHOLDER = '[Attachment]'.freeze

  pattr_initialize [:inbox!, :params!, { history_media_context: nil, history_media_identity: nil }]

  def self.history_media_context_for(message)
    attributes = message.content_attributes.to_h
    stored = Array.wrap(attributes['telegram_message_ids'])
    skipped = Array.wrap(attributes['telegram_history_media_skipped_message_ids'])
    references = {
      provider_ids: stored + skipped + [message.source_id],
      requested_ids: skipped.presence || stored.presence || [message.source_id]
    }
    references.transform_values! { |ids| ids.map { |id| TelegramPersonal::MessageSourceId.provider_id(id) }.reject(&:blank?).uniq.sort }
    { message_id: message.id }.merge(references)
  end

  def perform
    return unless supported_chat?

    existing_message = find_existing_message
    return reconcile_incomplete_history_media!(existing_message) if existing_message.present?
    return if history_media_context.present?
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

  def supported_chat?
    private_chat? || (group_chat? && inbox.channel.respond_to?(:sync_groups?) && inbox.channel.sync_groups?)
  end

  # The same decision as the skip of Telegram's service account (TelegramPersonal::ChatType)
  def private_chat?
    TelegramPersonal::ChatType.private?(params)
  end

  def group_chat?
    TelegramPersonal::ChatType.group?(params)
  end

  def find_existing_message
    return inbox.messages.find_by(id: history_media_context[:message_id]) if history_media_context.present?

    return find_existing_group_message if group_chat? && params[:chat_id].present?

    find_existing_private_message
  end

  def find_existing_group_message
    scoped = contact_inbox_messages(params[:chat_id])
    return if scoped.blank?

    candidates = TelegramPersonal::MessageSourceId.candidates(raw_storage_source_id, chat_id: params[:chat_id])
    scoped.where(source_id: candidates).first || find_existing_album_message(scoped)
  end

  def find_existing_private_message
    existing = inbox.messages.find_by(source_id: storage_source_id)
    if existing.present?
      legacy_group_id = legacy_group_chat_id_for(existing)
      return existing if legacy_group_id.blank?

      rekey_legacy_group_message!(existing, legacy_group_id)
    end
    return if params[:grouped_id].blank? || peer_user_id.blank?

    scoped = contact_inbox_messages(peer_user_id)
    find_existing_album_message(scoped) if scoped.present?
  end

  def legacy_group_chat_id_for(message)
    candidate = message.conversation&.additional_attributes.to_h['chat_id'].to_s.presence ||
                message.conversation&.contact_inbox&.source_id.to_s.presence
    candidate if candidate.to_s.start_with?('-')
  end

  def rekey_legacy_group_message!(message, group_chat_id)
    canonical_id = TelegramPersonal::MessageSourceId.format(message.source_id, chat_id: group_chat_id, group: true)
    return if canonical_id == message.source_id
    return if inbox.messages.exists?(source_id: canonical_id)

    message.skip_runtime_events = true
    message.update!(source_id: canonical_id)
  end

  def contact_inbox_messages(source_id)
    contact_inbox = inbox.contact_inboxes.find_by(source_id: source_id.to_s)
    return if contact_inbox.blank?

    inbox.messages.joins(:conversation).where(conversations: { contact_inbox_id: contact_inbox.id })
  end

  def find_existing_album_message(scoped)
    return if params[:grouped_id].blank?

    content_attrs = Message.attributes_object_sql('content_attributes', 'messages')
    scoped.where("#{content_attrs} ->> 'grouped_id' = ?", params[:grouped_id].to_s).first
  end

  def set_contact
    @contact_inbox = TelegramPersonal::ContactSyncService.new(
      inbox: inbox,
      params: params
    ).perform
    @contact = @contact_inbox&.contact
  end

  def set_conversation
    @conversation = TelegramPersonal::ConversationSyncService.new(
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
    attach_prepared_file(attachment, prepare_attachment_file(attachment))
  rescue StandardError => e
    track_unavailable_attachment(attachment, e)
    Rails.logger.info("[TELEGRAM PERSONAL] Attachment download failed for #{storage_source_id}: #{e.class}: #{e.message}")
    nil
  end

  def prepare_attachment_file(attachment)
    Down.download(attachment[:url])
  end

  def attach_prepared_file(attachment, attachment_file)
    @message.attachments.new(
      account_id: @message.account_id,
      file_type: normalized_file_type(attachment[:kind], attachment_file.content_type),
      meta: telegram_attachment_meta(attachment),
      file: {
        io: attachment_file,
        filename: attachment[:filename].presence || attachment_file.original_filename,
        content_type: attachment[:content_type].presence || attachment_file.content_type
      }
    ).skip_storage_limit_validation!
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
    return if @unavailable_attachments.blank? && !history_media_incomplete?
    return if @message.content.present?
    return if @message.attachments.present?

    @message.content = ATTACHMENT_PLACEHOLDER
  end

  def reconcile_incomplete_history_media!(message)
    return unless imported_history?
    return unless message.content_attributes.to_h['telegram_history_media_incomplete']
    return if history_media_incomplete?

    @message = message
    @history_context = history_media_context || self.class.history_media_context_for(message)
    @history_identity = history_media_identity || Messages::HistoryMediaIdentity.new(message)
    return unless history_media_context_current?

    prepared = []
    prepare_missing_history_media(prepared)
    persist_prepared_history_media(prepared)
  ensure
    prepared&.each { |_, file, _| file.close! if file.respond_to?(:close!) }
  end

  def persist_prepared_history_media(prepared)
    @message.with_lock do
      next unless history_media_context_current?

      @message.skip_runtime_events = true
      @unavailable_attachments = []
      prepared.each { |attachment, file, error| reconcile_prepared_attachment(attachment, file, error) }
      update_history_media_completion
      @message.save!
    end
  end

  def update_history_media_completion
    if history_media_enrichment_complete?
      complete_history_media_enrichment!
    else
      @message.content_attributes = @message.content_attributes.merge('telegram_history_media_skipped_message_ids' => missing_history_media_ids)
    end
  end

  def history_media_context_current?
    return false unless @history_identity.current?(@message)
    return false unless @message.content_attributes.to_h['telegram_history_media_incomplete']

    self.class.history_media_context_for(@message) == @history_context
  end

  def prepare_missing_history_media(prepared)
    Array.wrap(params[:attachments]).each do |attachment|
      next if attachment_already_present?(attachment)

      prepared << prepare_history_attachment(attachment)
    end
  end

  def prepare_history_attachment(attachment)
    id = attachment[:telegram_message_id].to_s
    if attachment[:url].blank? || @history_context[:requested_ids].exclude?(id)
      return [attachment, nil, ArgumentError.new('Unrequested history media')]
    end

    [attachment, prepare_attachment_file(attachment), nil]
  rescue StandardError => e
    [attachment, nil, e]
  end

  def reconcile_prepared_attachment(attachment, file, error)
    return if attachment_already_present?(attachment)
    return track_unavailable_attachment(attachment, error) if error

    attach_prepared_file(attachment, file)
  end

  def history_media_enrichment_complete?
    @history_context[:provider_ids].present? && @unavailable_attachments.blank? && missing_history_media_ids.empty?
  end

  def missing_history_media_ids
    attached_ids = @message.attachments.filter_map do |attachment|
      attachment.meta.to_h['telegram_message_id'].to_s.presence
    end
    @history_context[:provider_ids] - attached_ids
  end

  def complete_history_media_enrichment!
    content_attributes = @message.content_attributes.to_h.except(
      'telegram_history_media_incomplete',
      'telegram_history_media_skipped_message_ids',
      'telegram_unavailable_attachments'
    )
    @message.content_attributes = content_attributes
    @message.content = '' if @message.content == ATTACHMENT_PLACEHOLDER && params[:text].blank? && params[:caption].blank?
  end

  def attachment_already_present?(attachment)
    telegram_message_id = attachment[:telegram_message_id].to_s
    return false if telegram_message_id.blank?

    @message.attachments.any? do |existing_attachment|
      existing_attachment.meta.to_h['telegram_message_id'].to_s == telegram_message_id
    end
  end

  def telegram_attachment_meta(attachment)
    telegram_message_id = attachment[:telegram_message_id].to_s
    return {} if telegram_message_id.blank?

    { telegram_message_id: telegram_message_id }
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

  def raw_storage_source_id
    telegram_message_ids.first.presence || external_message_id
  end

  def storage_source_id
    TelegramPersonal::MessageSourceId.format(
      raw_storage_source_id,
      chat_id: params[:chat_id],
      group: group_chat?
    )
  end

  def matching_outgoing_message
    reference_time = provider_message_time || Time.current

    @conversation.messages.outgoing
                 .where(source_id: nil)
                 .where(created_at: (reference_time - 10.minutes)..(reference_time + 10.minutes))
                 .reorder(created_at: :desc)
                 .detect { |message| outgoing_message_matches_echo?(message) }
  end

  def outgoing_message_matches_echo?(message)
    stored_reply_to = TelegramPersonal::MessageSourceId.provider_id(message.content_attributes.to_h['in_reply_to_external_id'])
    incoming_reply_to = TelegramPersonal::MessageSourceId.provider_id(params[:reply_to_message_id])

    message.outgoing_content.to_s.strip == echo_content.to_s.strip &&
      stored_reply_to == incoming_reply_to &&
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
    prefix = group_chat? && params[:chat_id].present? ? "group:#{params[:chat_id]}:" : ''
    return "#{prefix}album:#{params[:grouped_id]}" if params[:grouped_id].present?

    "#{prefix}#{raw_storage_source_id}"
  end

  def telegram_message_ids
    Array.wrap(params[:telegram_message_ids]).map(&:to_s).reject(&:blank?).presence || [external_message_id].reject(&:blank?)
  end

  def conversation_additional_attributes
    if group_chat?
      return {
        chat_id: params[:chat_id],
        chat_type: params[:chat_type],
        is_group: true,
        chat_title: group_chat_title
      }.compact
    end

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
      attrs[:external_created_at] = provider_message_time.utc.iso8601 if provider_message_time.present?
      attrs[:imported_history] = true if imported_history?
      attrs.merge!(history_media_content_attributes)
      attrs[:in_reply_to_external_id] = formatted_reply_to_message_id if params[:reply_to_message_id].present?
      attrs[:telegram_message_ids] = telegram_message_ids if telegram_message_ids.many?
      attrs[:grouped_id] = params[:grouped_id].to_s if params[:grouped_id].present?
      attrs[:telegram_reactions] = params[:reactions].to_h if params[:reactions].present?
      attrs[:telegram_forwarded_from] = params[:forwarded_from].to_h if params[:forwarded_from].present?
      attrs[:group_sender] = group_sender_attributes if group_chat? && !outgoing_echo? && group_sender_attributes.present?
    end
  end

  def group_sender_attributes
    fields = raw_group_sender_fields
    full_name = fields[:name] || [fields[:first_name], fields[:last_name], fields[:username], fields[:phone_number], fields[:id]].compact.first
    return if full_name.blank? && fields[:id].blank?

    fields.merge(name: full_name).compact
  end

  def raw_group_sender_fields
    sender_payload = params[:group_sender].is_a?(Hash) ? params[:group_sender] : {}
    first_name = group_sender_field(sender_payload, :first_name)
    last_name = group_sender_field(sender_payload, :last_name)

    {
      id: group_sender_field(sender_payload, :id),
      name: group_sender_field(sender_payload, :name) || [first_name, last_name].compact.join(' ').presence,
      first_name: first_name,
      last_name: last_name,
      username: group_sender_field(sender_payload, :username),
      phone_number: group_sender_field(sender_payload, :phone_number),
      avatar_url: group_sender_field(sender_payload, :avatar_url)
    }
  end

  def group_sender_field(sender_payload, key)
    (sender_payload[key] || params[:"sender_#{key}"]).to_s.strip.presence
  end

  def group_chat_title
    params[:chat_title].presence || params[:title].presence
  end

  def history_media_content_attributes
    return {} unless history_media_incomplete?

    {
      telegram_history_media_incomplete: true,
      telegram_history_media_skipped_message_ids: history_media_skipped_message_ids
    }
  end

  def formatted_reply_to_message_id
    TelegramPersonal::MessageSourceId.format(
      params[:reply_to_message_id],
      chat_id: params[:chat_id],
      group: group_chat?
    )
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

  def history_media_incomplete?
    imported_history? && ActiveModel::Type::Boolean.new.cast(params[:history_media_incomplete])
  end

  def history_media_skipped_message_ids
    Array.wrap(params[:history_media_skipped_message_ids]).map(&:to_s).reject(&:blank?).uniq
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
    return params[:chat_id] if group_chat?

    params[:peer_user_id] || params[:sender_id] || params[:chat_id]
  end

  def voice_note?
    Array.wrap(params[:attachments]).any? do |attachment|
      attachment[:kind].to_s == 'voice'
    end
  end
end
