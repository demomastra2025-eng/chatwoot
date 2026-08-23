class Whatsapp::IncomingMessageMutationService
  class TargetNotFoundError < StandardError; end

  def self.replay_pending_for(message)
    Whatsapp::PendingMessageMutationService.replay_pending_for(message)
  end

  def initialize(inbox:, message:, outgoing_echo: false)
    @inbox = inbox
    @message = message&.with_indifferent_access
    @outgoing_echo = outgoing_echo
  end

  def perform
    Whatsapp::PendingMessageMutationService.new(inbox: inbox, message: message, outgoing_echo: outgoing_echo).perform
  end

  def apply_to(target_message)
    @target_message = target_message
    return :invalid if invalid_event_timestamp?

    process_mutation
  end

  private

  attr_reader :inbox, :message, :outgoing_echo

  def process_mutation
    case message[:type].to_s
    when 'reaction'
      process_reaction
    when 'edit'
      process_edit
    when 'revoke'
      process_revoke
    else
      :invalid
    end
  end

  def process_reaction
    reaction = message[:reaction].to_h.with_indifferent_access
    target = find_target(reaction[:message_id])
    return :pending if target.blank?

    target.with_lock { apply_reaction(target, reaction) }
  end

  def apply_reaction(target, reaction)
    content_attributes = target.content_attributes.to_h.deep_dup
    reactions = content_attributes['whatsapp_reactions'].to_h
    reaction_events = content_attributes['whatsapp_reaction_events'].to_h
    return :stale unless newer_event?(reaction_events[actor_id] || reactions[actor_id], 'event_id', 'timestamp')

    update_reactions(reactions, reaction)
    reaction_events[actor_id] = reaction_event_attributes
    persist_reactions(target, content_attributes, reactions, reaction_events)
    :applied
  end

  def persist_reactions(target, content_attributes, reactions, reaction_events)
    if reactions.present?
      content_attributes['whatsapp_reactions'] = reactions
    else
      content_attributes.delete('whatsapp_reactions')
    end
    content_attributes['whatsapp_reaction_events'] = reaction_events
    target.update!(content_attributes: content_attributes)
  end

  def update_reactions(reactions, reaction)
    if reaction[:emoji].present?
      reactions[actor_id] = reaction_attributes(reaction)
    else
      reactions.delete(actor_id)
    end
  end

  def reaction_attributes(reaction)
    {
      'emoji' => reaction[:emoji],
      **reaction_event_attributes
    }.compact
  end

  def reaction_event_attributes
    {
      'event_id' => message[:id],
      'timestamp' => normalized_event_timestamp
    }.compact
  end

  def actor_id
    message[:from_user_id].presence || message[:from].presence || (outgoing_echo ? 'business' : 'unknown')
  end

  def process_edit
    edit = message[:edit].to_h.with_indifferent_access
    target = find_target(edit[:original_message_id])
    return :pending if target.blank?

    edited_content = extract_edited_content(edit[:message])
    return :invalid if edited_content.blank?

    target.with_lock do
      content_attributes = target.content_attributes.to_h
      next :stale if content_attributes['deleted']
      next :stale unless newer_event?(content_attributes, 'whatsapp_edit_event_id', 'whatsapp_edited_at')

      target.update!(
        content: edited_content,
        content_attributes: content_attributes.merge(
          'edited' => true,
          'whatsapp_edit_event_id' => message[:id],
          'whatsapp_edited_at' => normalized_event_timestamp
        ).compact
      )
      :applied
    end
  end

  def extract_edited_content(raw_message)
    edited_message = raw_message.to_h.with_indifferent_access
    edited_type = edited_message[:type]
    edited_message.dig(:text, :body).presence || edited_message.dig(edited_type, :caption).presence
  end

  def process_revoke
    revoke = message[:revoke].to_h.with_indifferent_access
    target = find_target(revoke[:original_message_id])
    return :pending if target.blank?

    target.with_lock do
      content_attributes = target.content_attributes.to_h
      next :stale unless newer_event?(content_attributes, 'whatsapp_revoke_event_id', 'whatsapp_revoked_at')
      next :stale if older_than?(content_attributes['whatsapp_edited_at'])

      target.update!(
        content: I18n.t('conversations.messages.deleted'),
        content_type: :text,
        content_attributes: content_attributes.merge(revoke_attributes).compact
      )
      target.attachments.destroy_all
      :applied
    end
  end

  def revoke_attributes
    {
      'deleted' => true,
      'whatsapp_revoke_event_id' => message[:id],
      'whatsapp_revoked_at' => normalized_event_timestamp
    }
  end

  def newer_event?(attributes, event_id_key, timestamp_key)
    attributes = attributes.to_h.with_indifferent_access
    return false if attributes[event_id_key].present? && attributes[event_id_key].to_s == message[:id].to_s

    stored_timestamp = Whatsapp::ProviderTimestamp.normalize(attributes[timestamp_key])
    incoming_timestamp = normalized_event_timestamp_seconds
    return true if stored_timestamp.blank? || incoming_timestamp.blank?

    incoming_timestamp >= stored_timestamp
  end

  def older_than?(timestamp)
    stored_timestamp = Whatsapp::ProviderTimestamp.normalize(timestamp)
    incoming_timestamp = normalized_event_timestamp_seconds
    stored_timestamp.present? && incoming_timestamp.present? && incoming_timestamp < stored_timestamp
  end

  def normalized_event_timestamp
    normalized_event_timestamp_seconds&.to_s
  end

  def normalized_event_timestamp_seconds
    return @normalized_event_timestamp_seconds if defined?(@normalized_event_timestamp_seconds)

    @normalized_event_timestamp_seconds = Whatsapp::ProviderTimestamp.normalize(message[:timestamp])
  end

  def invalid_event_timestamp?
    message.key?(:timestamp) && Whatsapp::ProviderTimestamp.invalid_supplied?(message[:timestamp])
  end

  def find_target(source_id)
    return if source_id.blank?
    return @target_message if @target_message&.source_id.to_s == source_id.to_s

    Message.find_by(inbox_id: inbox.id, source_id: source_id.to_s)
  end
end
