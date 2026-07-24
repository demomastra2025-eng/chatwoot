class Whatsapp::WebhookBatchNormalizer
  pattr_initialize [:params!]

  def perform
    payloads = single_change_payloads.presence || [params.to_h.with_indifferent_access]
    payloads.flat_map { |payload| atomic_message_payloads(payload) }
  end

  private

  def atomic_message_payloads(payload)
    value = change_value(payload)
    message_keys = %i[messages statuses message_echoes calls].select { |key| value[key].present? }
    return [payload] if message_keys.empty?

    message_keys.flat_map do |key|
      Array(value[key]).map { |event| payload_for_message_event(payload, value, key, event) }
    end
  end

  def payload_for_message_event(payload, value, key, event)
    atomic_value = value.except(:messages, :statuses, :message_echoes, :calls).merge(key => [event])
    atomic_value[:contacts] = contacts_for_event(value[:contacts], event, key) if value.key?(:contacts) && key != :message_echoes

    change = payload.dig(:entry, 0, :changes, 0).to_h.with_indifferent_access
    payload.merge(entry: [payload[:entry].first.merge(changes: [change.merge(value: atomic_value)])])
  end

  def contacts_for_event(contacts, event, key)
    contacts = Array(contacts)
    event = event.to_h.with_indifferent_access
    event_ids = event_ids(event, key)
    return contacts if event_ids.empty?

    matching_contact = contacts.find do |contact|
      contact_ids = contact.to_h.with_indifferent_access.values_at(:wa_id, :user_id, :parent_user_id).compact_blank.map(&:to_s)
      contact_ids.intersect?(event_ids)
    end
    matching_contact.present? ? [matching_contact] : []
  end

  def event_ids(event, key)
    keys = key == :statuses ? %i[recipient_id recipient_user_id recipient_parent_user_id] : %i[from from_user_id from_parent_user_id]
    event.values_at(*keys).compact_blank.map(&:to_s)
  end

  def single_change_payloads
    original = params.to_h.deep_dup.with_indifferent_access
    Array(original[:entry]).flat_map do |entry|
      entry = entry.to_h.with_indifferent_access
      Array(entry[:changes]).map do |change|
        original.merge(entry: [entry.merge(changes: [change])])
      end
    end
  end

  def change_value(payload)
    payload.dig(:entry, 0, :changes, 0, :value).to_h.with_indifferent_access
  end
end
