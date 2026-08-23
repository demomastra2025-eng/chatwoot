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
    process_mutation
    true
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
      return false
    end
  end

  def process_reaction
    reaction = message[:reaction].to_h.with_indifferent_access
    target = find_target(reaction[:message_id])
    return if target.blank?

    target.with_lock { apply_reaction(target, reaction) }
  end

  def apply_reaction(target, reaction)
    content_attributes = target.content_attributes.to_h.deep_dup
    reactions = content_attributes['whatsapp_reactions'].to_h
    reaction_events = content_attributes['whatsapp_reaction_events'].to_h
    return unless newer_event?(reaction_events[actor_id] || reactions[actor_id], 'event_id', 'timestamp')

    update_reactions(reactions, reaction)
    reaction_events[actor_id] = reaction_event_attributes
    persist_reactions(target, content_attributes, reactions, reaction_events)
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
      'timestamp' => message[:timestamp]
    }.compact
  end

  def actor_id
    message[:from_user_id].presence || message[:from].presence || (outgoing_echo ? 'business' : 'unknown')
  end

  def process_edit
    edit = message[:edit].to_h.with_indifferent_access
    target = find_target(edit[:original_message_id])
    return if target.blank?

    edited_content = extract_edited_content(edit[:message])
    return if edited_content.blank?

    target.with_lock do
      content_attributes = target.content_attributes.to_h
      next if content_attributes['deleted']
      next unless newer_event?(content_attributes, 'whatsapp_edit_event_id', 'whatsapp_edited_at')

      target.update!(
        content: edited_content,
        content_attributes: content_attributes.merge(
          'edited' => true,
          'whatsapp_edit_event_id' => message[:id],
          'whatsapp_edited_at' => message[:timestamp]
        ).compact
      )
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
    return if target.blank?

    target.with_lock do
      content_attributes = target.content_attributes.to_h
      next unless newer_event?(content_attributes, 'whatsapp_revoke_event_id', 'whatsapp_revoked_at')
      next if older_than?(content_attributes['whatsapp_edited_at'])

      target.update!(
        content: I18n.t('conversations.messages.deleted'),
        content_type: :text,
        content_attributes: content_attributes.merge(revoke_attributes).compact
      )
      target.attachments.destroy_all
    end
  end

  def revoke_attributes
    {
      'deleted' => true,
      'whatsapp_revoke_event_id' => message[:id],
      'whatsapp_revoked_at' => message[:timestamp]
    }
  end

  def newer_event?(attributes, event_id_key, timestamp_key)
    attributes = attributes.to_h.with_indifferent_access
    return false if attributes[event_id_key].present? && attributes[event_id_key].to_s == message[:id].to_s
    return true if attributes[timestamp_key].blank? || message[:timestamp].blank?

    message[:timestamp].to_i >= attributes[timestamp_key].to_i
  end

  def older_than?(timestamp)
    timestamp.present? && message[:timestamp].present? && message[:timestamp].to_i < timestamp.to_i
  end

  def find_target(source_id)
    return if source_id.blank?
    return @target_message if @target_message&.source_id.to_s == source_id.to_s

    Message.find_by(inbox_id: inbox.id, source_id: source_id.to_s)
  end
end
