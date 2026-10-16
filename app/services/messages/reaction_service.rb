class Messages::ReactionService
  class Error < StandardError; end

  pattr_initialize [:message!, :user, :emoji]

  def perform
    validate_message!
    normalized_emoji = emoji.to_s.strip
    validate_emoji!(normalized_emoji)

    effective_emoji = resolve_effective_emoji(normalized_emoji)
    dispatch_to_provider!(effective_emoji) if should_dispatch_to_provider?

    message.with_lock do
      apply_reaction_attributes!(effective_emoji)
    end

    message
  rescue StandardError => e
    raise e if e.is_a?(Error)

    raise Error, e.message
  end

  private

  delegate :conversation, to: :message
  delegate :inbox, to: :conversation
  delegate :channel, to: :inbox

  def validate_message!
    raise Error, 'Cannot react to activity messages' if message.activity?
    raise Error, 'Cannot react to private notes' if message.private?
    raise Error, 'Cannot react to deleted messages' if (message.content_attributes || {}).with_indifferent_access[:deleted]
    raise Error, 'Reactions are not supported for this channel' unless reaction_supported_channel?
    raise Error, 'Cannot react to a message without external source_id' if message.source_id.blank?
  end

  def reaction_supported_channel?
    whatsapp_cloud_channel? ||
      channel.is_a?(Channel::WhatsappWeb) ||
      telegram_like_channel?
  end

  def whatsapp_cloud_channel?
    channel.is_a?(Channel::Whatsapp) && channel.provider == 'whatsapp_cloud'
  end

  def validate_emoji!(value)
    return if value.blank?
    return if valid_single_emoji?(value)

    raise Error, 'Reaction must contain a single valid emoji'
  end

  def valid_single_emoji?(value)
    return false unless value.scan(/\X/).one?

    value.match?(/\p{Emoji_Presentation}|\p{Extended_Pictographic}/) ||
      value.match?(/\A[#*0-9]\uFE0F?\u20E3\z/)
  end

  def actor_key
    user&.id.present? ? "user:#{user.id}" : 'agent'
  end

  def resolve_effective_emoji(requested_emoji)
    return '' if requested_emoji.blank?

    current_emoji = current_actor_emoji
    current_emoji == requested_emoji ? '' : requested_emoji
  end

  def current_actor_emoji
    attrs = (message.content_attributes || {}).to_h.deep_stringify_keys
    agent_emoji = attrs.dig('agent_reactions', actor_key, 'emoji').to_s.presence
    return agent_emoji if agent_emoji.present?

    if whatsapp_like_channel?
      return attrs.dig('whatsapp_reactions', 'business', 'emoji').to_s.presence
    end

    if telegram_like_channel?
      chosen_entry = Array(attrs.dig('telegram_reactions', 'results')).find do |item|
        ActiveModel::Type::Boolean.new.cast(item.to_h['chosen'])
      end
      return chosen_entry.to_h.dig('reaction', 'emoji').to_s.presence
    end

    nil
  end

  def should_dispatch_to_provider?
    !message.private? && message.source_id.present?
  end

  def dispatch_to_provider!(effective_emoji)
    case channel
    when Channel::Whatsapp
      dispatch_whatsapp_cloud_reaction!(effective_emoji)
    when Channel::WhatsappWeb
      channel.provider_service.send_reaction(message: message, emoji: effective_emoji)
    when Channel::Telegram
      channel.send_reaction(message: message, emoji: effective_emoji)
    when Channel::TelegramPersonal
      dispatch_telegram_personal_reaction!(effective_emoji)
    end
  end

  def dispatch_whatsapp_cloud_reaction!(effective_emoji)
    return unless channel.provider == 'whatsapp_cloud'

    recipient = resolve_whatsapp_recipient_source_id
    raise Error, Whatsapp::SendOnWhatsappService::MISSING_RECIPIENT_ERROR if recipient.blank?

    channel.provider_service.send_reaction(
      recipient,
      message.source_id,
      effective_emoji,
      conversation: conversation
    )
  end

  def resolve_whatsapp_recipient_source_id
    recipient_contact = conversation.contact_inbox&.contact || conversation.contact
    contact_inbox = Whatsapp::PreferredContactInboxResolver.new(
      contact: recipient_contact,
      inbox: inbox,
      fallback_contact_inbox: conversation.contact_inbox
    ).perform
    source_id = contact_inbox&.source_id
    Whatsapp::ContactIdentityResolver.phone_source_id(source_id) ||
      Whatsapp::ContactIdentityResolver.bsuid_source_id(source_id)
  end

  def dispatch_telegram_personal_reaction!(effective_emoji)
    TelegramPersonal::GatewayClient.new(channel: channel).react_message!(
      message: message,
      emoji: effective_emoji
    )
  rescue TelegramPersonal::GatewayClient::GatewayError => e
    Rails.logger.warn("[TELEGRAM PERSONAL] Reaction gateway call failed for message=#{message.id}: #{e.message}")
  end

  def apply_reaction_attributes!(effective_emoji)
    content_attributes = (message.content_attributes || {}).to_h.deep_dup.deep_stringify_keys
    previous_emoji = current_actor_emoji

    update_agent_reactions!(content_attributes, effective_emoji)
    update_whatsapp_reactions!(content_attributes, effective_emoji) if whatsapp_like_channel?
    update_telegram_reactions!(content_attributes, previous_emoji, effective_emoji) if telegram_like_channel?

    message.update!(content_attributes: content_attributes)
  end

  def update_agent_reactions!(content_attributes, effective_emoji)
    agent_reactions = content_attributes['agent_reactions'].to_h
    if whatsapp_like_channel? || telegram_like_channel?
      # Single outgoing account identity on external messenger channels
      agent_reactions.clear if effective_emoji.blank?
    end

    if effective_emoji.present?
      agent_reactions[actor_key] = {
        'emoji' => effective_emoji,
        'user_id' => user&.id,
        'user_name' => user&.name,
        'updated_at' => Time.current.iso8601
      }.compact
    else
      agent_reactions.delete(actor_key)
    end

    if agent_reactions.present?
      content_attributes['agent_reactions'] = agent_reactions
    else
      content_attributes.delete('agent_reactions')
    end
  end

  def update_whatsapp_reactions!(content_attributes, effective_emoji)
    reactions = content_attributes['whatsapp_reactions'].to_h
    reaction_events = content_attributes['whatsapp_reaction_events'].to_h
    now_ts = Time.current.to_i.to_s

    if effective_emoji.present?
      reactions['business'] = {
        'emoji' => effective_emoji,
        'user_id' => user&.id,
        'user_name' => user&.name,
        'timestamp' => now_ts
      }.compact
    else
      reactions.delete('business')
    end

    reaction_events['business'] = { 'timestamp' => now_ts }

    if reactions.present?
      content_attributes['whatsapp_reactions'] = reactions
    else
      content_attributes.delete('whatsapp_reactions')
    end
    content_attributes['whatsapp_reaction_events'] = reaction_events
  end

  def update_telegram_reactions!(content_attributes, previous_emoji, effective_emoji)
    existing = content_attributes['telegram_reactions'].to_h
    results = Array(existing['results']).map do |entry|
      item = entry.to_h.deep_stringify_keys
      item['reaction'] = item['reaction'].to_h
      item['count'] = item['count'].to_i
      item
    end

    if previous_emoji.present?
      prev_item = results.find { |r| r.dig('reaction', 'emoji') == previous_emoji }
      if prev_item
        prev_item['count'] = [prev_item['count'].to_i - 1, 0].max
        prev_item.delete('chosen')
      end
    end

    if effective_emoji.present?
      target_item = results.find { |r| r.dig('reaction', 'emoji') == effective_emoji }
      if target_item
        target_item['count'] = target_item['count'].to_i + 1
        target_item['chosen'] = true
      else
        results << {
          'reaction' => { 'type' => 'emoji', 'emoji' => effective_emoji },
          'count' => 1,
          'chosen' => true
        }
      end
    end

    results.reject! { |r| r['count'].to_i <= 0 }
    content_attributes['telegram_reactions'] = {
      'total_count' => results.sum { |r| r['count'].to_i },
      'results' => results
    }
  end

  def whatsapp_like_channel?
    channel.is_a?(Channel::Whatsapp) || channel.is_a?(Channel::WhatsappWeb)
  end

  def telegram_like_channel?
    channel.is_a?(Channel::Telegram) || channel.is_a?(Channel::TelegramPersonal)
  end
end
