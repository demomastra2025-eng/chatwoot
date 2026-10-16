# Find the various telegram payload samples here: https://core.telegram.org/bots/webhooks#testing-your-bot-with-updates
# https://core.telegram.org/bots/api#available-types

class Telegram::UpdateMessageService
  pattr_initialize [:inbox!, :params!]

  def perform
    if params[:message_reaction].present?
      process_message_reaction
      return
    end

    transform_business_message!
    find_contact_inbox
    find_conversation
    find_message
    update_message
  rescue StandardError => e
    Rails.logger.error "Error while processing telegram message update #{e.message}"
  end

  private

  def find_contact_inbox(chat_id = nil)
    resolved_chat_id = chat_id || params.dig(:edited_message, :chat, :id)
    @contact_inbox = inbox.contact_inboxes.find_by!(source_id: resolved_chat_id)
  end

  def find_conversation
    @conversation = @contact_inbox.conversations.last
  end

  def find_message(message_id = nil)
    resolved_message_id = message_id || params.dig(:edited_message, :message_id)
    @message = @conversation.messages.find_by(source_id: resolved_message_id.to_s)
  end

  def update_message
    edited_message = params[:edited_message]
    updated_content = edited_message[:text].presence || edited_message[:caption].presence
    return if updated_content.blank? || @message.blank?

    @message.update!(
      content: updated_content,
      content_attributes: (@message.content_attributes || {}).merge(edited: true)
    )
  end

  def process_message_reaction
    reaction_event = params[:message_reaction].to_h.with_indifferent_access
    chat_id = reaction_event.dig(:chat, :id)
    message_id = reaction_event[:message_id]
    return if chat_id.blank? || message_id.blank?

    find_contact_inbox(chat_id)
    find_conversation
    return if @conversation.blank?

    find_message(message_id)
    return if @message.blank?

    @message.with_lock do
      content_attributes = (@message.content_attributes || {}).deep_dup.with_indifferent_access
      telegram_reactions = apply_telegram_reaction_diff(
        content_attributes[:telegram_reactions],
        old_reactions: Array(reaction_event[:old_reaction]),
        new_reactions: Array(reaction_event[:new_reaction])
      )
      content_attributes[:telegram_reactions] = telegram_reactions
      @message.update!(content_attributes: content_attributes.to_h)
    end
  end

  def apply_telegram_reaction_diff(existing_payload, old_reactions:, new_reactions:)
    results = Array(existing_payload.to_h.with_indifferent_access[:results]).map do |entry|
      item = entry.to_h.deep_stringify_keys
      item['reaction'] = item['reaction'].to_h
      item['count'] = item['count'].to_i
      item
    end

    old_reactions.each do |raw|
      norm = normalize_telegram_reaction_item(raw)
      next if norm.blank?

      found = results.find { |r| r['reaction'] == norm }
      next unless found

      found['count'] = [found['count'] - 1, 0].max
    end

    new_reactions.each do |raw|
      norm = normalize_telegram_reaction_item(raw)
      next if norm.blank?

      found = results.find { |r| r['reaction'] == norm }
      if found
        found['count'] += 1
      else
        results << { 'reaction' => norm, 'count' => 1 }
      end
    end

    results.reject! { |r| r['count'].to_i <= 0 }
    total_count = results.sum { |r| r['count'].to_i }

    {
      'total_count' => total_count,
      'results' => results
    }
  end

  def normalize_telegram_reaction_item(raw)
    item = raw.to_h.with_indifferent_access
    type = item[:type].to_s.presence || 'emoji'
    if type == 'emoji' && item[:emoji].present?
      { 'type' => 'emoji', 'emoji' => item[:emoji].to_s }
    elsif type == 'custom_emoji' && item[:custom_emoji_id].present?
      { 'type' => 'custom_emoji', 'custom_emoji_id' => item[:custom_emoji_id].to_s }
    elsif type == 'paid'
      { 'type' => 'paid' }
    end
  end

  def transform_business_message!
    params[:edited_message] = params[:edited_business_message] if params[:edited_business_message].present?
  end
end
