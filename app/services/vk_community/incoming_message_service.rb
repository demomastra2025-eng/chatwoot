class VkCommunity::IncomingMessageService
  include ::FileTypeHelper

  pattr_initialize [:inbox!, :params!]

  def perform
    return unless direct_message?
    return if inbox.messages.exists?(source_id: message_payload[:id].to_s)

    set_contact
    set_conversation
    build_message
    attach_files
    attach_location
    @message.save!
  end

  private

  def direct_message?
    peer_id.to_i.positive? && peer_id.to_i < 2_000_000_000
  end

  def set_contact
    profile = inbox.channel.api_client.user_profile(from_id)
    contact_inbox = ::ContactInboxWithContactBuilder.new(
      source_id: peer_id.to_s,
      inbox: inbox,
      contact_attributes: contact_attributes(profile)
    ).perform
    @contact_inbox = contact_inbox
    @contact = contact_inbox.contact
    update_avatar(profile)
  end

  def update_avatar(profile)
    return if @contact.avatar.attached?
    return if profile[:photo_200].blank?

    ::Avatar::AvatarFromUrlJob.perform_later(@contact, profile[:photo_200])
  end

  def contact_attributes(profile)
    city = profile[:city].is_a?(Hash) ? profile[:city]['title'] || profile[:city][:title] : profile[:city]
    {
      name: [profile[:first_name], profile[:last_name]].compact.join(' ').strip.presence || profile[:screen_name].presence || from_id.to_s,
      avatar_url: profile[:photo_200],
      additional_attributes: {
        social_vk_user_id: from_id,
        social_vk_screen_name: profile[:screen_name],
        city: city,
        vk_bdate: profile[:bdate]
      }.compact
    }
  end

  def set_conversation
    @conversation = if inbox.lock_to_single_conversation
                      @contact_inbox.conversations.last
                    else
                      @contact_inbox.conversations.where.not(status: :resolved).last
                    end
    return if @conversation.present?

    @conversation = ::Conversation.create!(
      account_id: inbox.account_id,
      inbox_id: inbox.id,
      contact_id: @contact.id,
      contact_inbox_id: @contact_inbox.id,
      additional_attributes: {
        peer_id: peer_id,
        from_id: from_id
      }
    )
  end

  def build_message
    @message = @conversation.messages.build(
      content: message_payload[:text].to_s,
      account_id: inbox.account_id,
      inbox_id: inbox.id,
      message_type: :incoming,
      sender: @contact,
      source_id: message_payload[:id].to_s
    )
  end

  def attach_files
    Array.wrap(message_payload[:attachments]).each do |attachment|
      normalized = normalize_attachment(attachment.with_indifferent_access)
      next if normalized[:url].blank?

      attachment_file = Down.download(normalized[:url])
      @message.attachments.new(
        account_id: @message.account_id,
        file_type: normalized[:file_type],
        file: {
          io: attachment_file,
          filename: normalized[:filename].presence || attachment_file.original_filename,
          content_type: attachment_file.content_type
        }
      ).skip_storage_limit_validation!
    end
  end

  def attach_location
    geo = message_payload[:geo].to_h
    coordinates = geo[:coordinates].to_s.split(/\s+/)
    return unless coordinates.size == 2

    @message.attachments.new(
      account_id: @message.account_id,
      file_type: :location,
      coordinates_lat: coordinates[0],
      coordinates_long: coordinates[1],
      fallback_title: geo.dig(:place, :title).to_s
    ).skip_storage_limit_validation!
  end

  def normalize_attachment(attachment)
    case attachment[:type].to_s
    when 'photo'
      photo = attachment.dig(:photo, :sizes).to_a.max_by { |entry| entry[:width].to_i * entry[:height].to_i }.to_h
      { url: photo[:url], file_type: :image, filename: 'vk-photo.jpg' }
    when 'doc'
      doc = attachment[:doc].to_h
      { url: doc[:url], file_type: :file, filename: doc[:title] || 'vk-doc' }
    when 'audio_message'
      audio = attachment[:audio_message].to_h
      { url: audio[:link_ogg] || audio[:link_mp3], file_type: :audio, filename: 'vk-audio.ogg' }
    when 'sticker'
      image = attachment.dig(:sticker, :images_with_background).to_a.max_by { |entry| entry[:width].to_i * entry[:height].to_i }.to_h
      { url: image[:url], file_type: :file, filename: 'vk-sticker.png' }
    else
      {}
    end
  end

  def message_payload
    @message_payload ||= params.dig(:object, :message).to_h.deep_symbolize_keys
  end

  def peer_id
    message_payload[:peer_id]
  end

  def from_id
    message_payload[:from_id]
  end
end
