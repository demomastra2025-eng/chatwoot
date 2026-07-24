require 'digest'

class Whatsapp::MarketingPreferenceService
  CATEGORY = 'marketing_messages'.freeze
  VALUES = %w[stop resume].freeze
  PENDING_KEY = 'pending_marketing_preferences'.freeze
  INVALID_COUNT_KEY = 'invalid_marketing_preferences_count'.freeze

  def initialize(channel:, lifecycle_state:)
    @channel = channel
    @lifecycle_state = lifecycle_state
  end

  def apply(raw_preference)
    preference = raw_preference.to_h.with_indifferent_access
    return :unsupported unless preference[:category] == CATEGORY && VALUES.include?(preference[:value])

    normalized = normalized_preference(preference)
    unless normalized
      increment_invalid_count!
      return :invalid
    end

    contact_inbox = @channel.inbox.contact_inboxes.find_by(source_id: normalized['wa_id'])
    return store_pending(normalized) if contact_inbox.blank?

    applied = apply_to_contact(contact_inbox.contact, normalized['wa_id'], normalized)
    remove_pending(normalized['wa_id'])
    applied ? :applied : :duplicate
  end

  def replay_for(contact_inbox)
    wa_id = contact_inbox.source_id.to_s
    pending = pending_preferences[wa_id]
    return :missing if pending.blank?

    applied = apply_to_contact(contact_inbox.contact, wa_id, pending)
    remove_pending(wa_id)
    applied ? :applied : :superseded
  end

  private

  def normalized_preference(preference)
    timestamp = normalized_timestamp(preference[:timestamp])
    wa_id = preference[:wa_id].to_s
    return if timestamp.blank? || wa_id.blank?

    {
      'wa_id' => wa_id,
      'value' => preference[:value],
      'timestamp' => timestamp,
      'channel_id' => @channel.id
    }
  end

  def normalized_timestamp(value)
    return value if value.is_a?(Integer) && value.positive?

    raw = value.to_s
    return unless raw.match?(/\A\d+\z/) && raw.to_i.positive?

    raw.to_i
  end

  def store_pending(incoming)
    wa_id = incoming['wa_id']
    next_state, changed = reduce_state(pending_preferences[wa_id], incoming, wa_id)
    return :duplicate unless changed

    pending_preferences[wa_id] = next_state
    :pending
  end

  def apply_to_contact(contact, wa_id, incoming)
    contact.with_lock do
      attributes = contact.reload.additional_attributes.to_h.deep_stringify_keys
      current = attributes['whatsapp_marketing_preference'].to_h
      next_state, changed = reduce_state(current, incoming, wa_id)
      next false unless changed

      attributes['whatsapp_marketing_preference'] = next_state
      contact.update!(additional_attributes: attributes)
      true
    end
  end

  def reduce_state(current, incoming, wa_id)
    current = current.to_h.deep_stringify_keys
    incoming = incoming.to_h.deep_stringify_keys
    current_timestamp = normalized_timestamp(current['timestamp'])
    incoming_timestamp = normalized_timestamp(incoming['timestamp'])
    return [current, false] if incoming_timestamp.blank?
    return [current, false] if current_timestamp.present? && current_timestamp > incoming_timestamp

    incoming_fingerprints = event_fingerprints(incoming, wa_id)
    current_fingerprints = event_fingerprints(current, wa_id)
    return [current, false] if current_timestamp == incoming_timestamp && (incoming_fingerprints - current_fingerprints).empty?

    fingerprints = if current_timestamp == incoming_timestamp
                     (current_fingerprints + incoming_fingerprints).uniq
                   else
                     incoming_fingerprints
                   end
    next_state = incoming.slice('value', 'timestamp', 'channel_id').merge('event_fingerprints' => fingerprints)
    [next_state, true]
  end

  def event_fingerprints(state, wa_id)
    fingerprints = Array(state['event_fingerprints']).compact_blank.map(&:to_s).uniq
    return fingerprints if fingerprints.present?
    return [] if state['value'].blank? || normalized_timestamp(state['timestamp']).blank?

    [event_fingerprint(state, wa_id)]
  end

  def event_fingerprint(state, wa_id)
    values = [wa_id, state['value'], normalized_timestamp(state['timestamp']), state['channel_id'] || @channel.id]
    Digest::SHA256.hexdigest(values.map(&:to_s).join("\0"))
  end

  def pending_preferences
    @lifecycle_state[PENDING_KEY] ||= {}
  end

  def remove_pending(wa_id)
    pending_preferences.delete(wa_id)
    @lifecycle_state.delete(PENDING_KEY) if pending_preferences.empty?
  end

  def increment_invalid_count!
    @lifecycle_state[INVALID_COUNT_KEY] = @lifecycle_state[INVALID_COUNT_KEY].to_i + 1
  end
end
