class Whatsapp::PendingMessageMutationService
  MUTATION_EVENT_TYPES = %w[reaction edit revoke].freeze

  def self.replay_pending_for(message)
    return if message.blank? || message.inbox_id.blank? || message.source_id.blank?

    Whatsapp::PendingMessageMutation
      .pending
      .where(inbox_id: message.inbox_id, target_source_id: message.source_id)
      .order(:provider_timestamp, :id)
      .each do |pending_mutation|
        new(inbox: message.inbox, message: nil).replay(pending_mutation)
      end
  end

  def initialize(inbox:, message:, outgoing_echo: false)
    @inbox = inbox
    @message = message&.with_indifferent_access
    @outgoing_echo = outgoing_echo
  end

  def perform
    return false unless message.present? && MUTATION_EVENT_TYPES.include?(message[:type].to_s)
    return true unless persistable_event?

    pending_mutation = persist_pending_mutation!
    return true unless pending_mutation.pending?

    if Whatsapp::ProviderTimestamp.invalid_supplied?(message[:timestamp])
      mark_invalid!(pending_mutation)
      return true
    end

    result = replay(pending_mutation)
    schedule_reconciliation(pending_mutation) if result == :pending
    true
  end

  def replay(pending_mutation)
    pending_mutation.with_lock do
      target_message = inbox.messages.find_by(source_id: pending_mutation.target_source_id)
      next record_missing_target(pending_mutation) if target_message.blank?

      finalize_replay(pending_mutation, target_message)
    end
  rescue ActiveRecord::RecordNotFound
    :processed
  end

  private

  attr_reader :inbox, :message, :outgoing_echo

  def persistable_event?
    if message[:id].blank? || target_source_id.blank?
      Rails.logger.warn("[WHATSAPP] Ignored malformed mutation type=#{message[:type]}")
      return false
    end

    true
  end

  def persist_pending_mutation!
    Whatsapp::PendingMessageMutation.create_or_find_by!(inbox_id: inbox.id, event_id: message[:id].to_s) do |pending_mutation|
      pending_mutation.assign_attributes(pending_mutation_attributes)
    end
  end

  def pending_mutation_attributes
    {
      account_id: inbox.account_id,
      target_source_id: target_source_id,
      mutation_type: message[:type].to_s,
      actor_id: actor_id,
      provider_timestamp: Whatsapp::ProviderTimestamp.normalize(message[:timestamp]).to_i,
      payload: normalized_payload
    }
  end

  def record_missing_target(pending_mutation)
    pending_mutation.record_attempt!
    :pending
  end

  def finalize_replay(pending_mutation, target_message)
    result = Whatsapp::IncomingMessageMutationService
             .new(inbox: inbox, message: mutation_message_from_record(pending_mutation))
             .apply_to(target_message)
    return destroy_processed!(pending_mutation) if %i[applied stale].include?(result)
    return mark_invalid!(pending_mutation) if result == :invalid

    :pending
  end

  def destroy_processed!(pending_mutation)
    pending_mutation.destroy!
    :processed
  end

  def mark_invalid!(pending_mutation)
    pending_mutation.mark_invalid!
    :invalid
  end

  def schedule_reconciliation(pending_mutation)
    pending_mutation.schedule_reconciliation_at!(pending_mutation.expires_at)
  end

  def normalized_payload
    case message[:type].to_s
    when 'reaction'
      { 'emoji' => message.dig(:reaction, :emoji).to_s }
    when 'edit'
      { 'content' => edited_content }
    else
      {}
    end
  end

  def target_source_id
    case message[:type].to_s
    when 'reaction'
      message.dig(:reaction, :message_id).to_s.presence
    when 'edit'
      message.dig(:edit, :original_message_id).to_s.presence
    when 'revoke'
      message.dig(:revoke, :original_message_id).to_s.presence
    end
  end

  def edited_content
    edited_message = message.dig(:edit, :message).to_h.with_indifferent_access
    edited_type = edited_message[:type]
    edited_message.dig(:text, :body).presence || edited_message.dig(edited_type, :caption).presence
  end

  def actor_id
    message[:from_user_id].presence || message[:from].presence || (outgoing_echo ? 'business' : 'unknown')
  end

  def mutation_message_from_record(record)
    stored_message = {
      id: record.event_id,
      type: record.mutation_type,
      from: record.actor_id
    }.with_indifferent_access
    stored_message[:timestamp] = record.provider_timestamp.to_s if record.provider_timestamp.positive?

    stored_message[record.mutation_type] = mutation_payload(record)
    stored_message
  end

  def mutation_payload(record)
    case record.mutation_type
    when 'reaction'
      { message_id: record.target_source_id, emoji: record.payload.to_h['emoji'].to_s }
    when 'edit'
      {
        original_message_id: record.target_source_id,
        message: { type: 'text', text: { body: record.payload.to_h['content'] } }
      }
    when 'revoke'
      { original_message_id: record.target_source_id }
    end
  end
end
