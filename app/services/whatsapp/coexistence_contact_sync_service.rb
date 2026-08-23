require 'digest'

class Whatsapp::CoexistenceContactSyncService
  include Whatsapp::CoexistenceContactPendingEventHelpers

  MAX_EVENT_KEYS_PER_TIMESTAMP = 32
  MAX_QUARANTINED_EVENT_KEYS = 50

  def initialize(channel:, value:, provider_event_at: nil, pending_after_id: nil, pending_until_id: nil)
    @channel = channel
    @value = value.with_indifferent_access
    @provider_event_at = provider_event_at
    @pending_after_id = pending_after_id.to_i if pending_after_id.present?
    @pending_until_id = pending_until_id.to_i if pending_until_id.present?
  end

  def perform
    @quarantined_events = []
    load_pending_events
    entries = state_entries.map(&:with_indifferent_access)
    processed_entries = entries.select { |entry| apply_entry(entry) }
    processed_entries.concat(replay_pending_entries)
    update_sync_activity(processed_entries)
    enqueue_pending_event_reconciliation
  end

  private

  def state_entries
    Array(@value[:state_sync])
  end

  def apply_entry(entry)
    contact = entry[:contact].to_h.with_indifferent_access
    phone_number = normalize_phone(contact[:phone_number])
    return false if phone_number.blank?

    event = contact_event(entry, contact, phone_number)
    unless event
      quarantine_event(entry, 'invalid_timestamp')
      return false
    end

    resolver = contact_identity_resolver(phone_number, contact)
    contact_inbox = resolve_contact_inbox(entry, resolver)
    if contact_inbox.blank?
      pend_contact_event(entry, event) if entry[:action] == 'remove'
      return false
    end

    apply_contact_event(contact_inbox, entry, contact, resolver.source_id || phone_number, event)
  end

  def resolve_contact_inbox(entry, resolver)
    return resolver.perform if entry[:action] == 'add'

    @channel.inbox.contact_inboxes.find_by(source_id: resolver.source_ids)
  end

  def apply_contact_event(contact_inbox, entry, contact, phone_number, event)
    result = update_contact_state(contact_inbox.contact, entry, contact, phone_number, event)
    replay_pending_marketing_preference(contact_inbox) if entry[:action] == 'add'
    quarantine_event(entry, 'same_timestamp_event_overflow') if result == :overflow
    clear_pending_event(event[:key])
    result == true
  end

  def contact_identity_resolver(phone_number, contact)
    Whatsapp::ContactIdentityResolver.new(
      inbox: @channel.inbox,
      contact_params: {
        wa_id: phone_number,
        profile: { name: contact[:full_name].presence || contact[:first_name].presence || phone_number }
      },
      message: { from: phone_number }
    )
  end

  def update_contact_state(contact_record, entry, contact, phone_number, event)
    contact_record.with_lock do
      attributes = contact_record.additional_attributes.to_h.deep_dup
      states = attributes['whatsapp_business_app_contacts'].to_h
      current = states[@channel.inbox.id.to_s].to_h
      applicable = contact_event_applicable?(current, event)
      next applicable unless applicable == true

      states[@channel.inbox.id.to_s] = contact_state(current, entry, contact, phone_number, event)
      attributes['whatsapp_business_app_contacts'] = states
      contact_record.update!(additional_attributes: attributes)
      true
    end
  end

  def contact_state(current, entry, contact, phone_number, event)
    {
      'state' => entry[:action] == 'remove' ? 'removed' : 'active',
      'phone_number' => phone_number,
      'first_name' => contact[:first_name],
      'full_name' => contact[:full_name],
      'timestamp' => event[:timestamp],
      'event_key' => event[:key],
      'event_keys' => contact_event_keys_for_state(current, event)
    }.compact
  end

  def contact_event(entry, contact, phone_number)
    raw_timestamp = entry.dig(:metadata, :timestamp)
    timestamp = normalized_timestamp(raw_timestamp)
    timestamp ||= normalized_timestamp(@provider_event_at) if raw_timestamp.blank?
    return if timestamp.blank?

    values = [timestamp, entry[:action], phone_number, contact[:first_name], contact[:full_name]]
    { timestamp: timestamp, key: Digest::SHA256.hexdigest(values.map(&:to_s).join("\0")) }
  end

  def normalized_timestamp(raw_timestamp)
    return unless raw_timestamp.to_s.match?(/\A\d+\z/) && raw_timestamp.to_i.positive?

    timestamp = raw_timestamp.to_i
    timestamp /= 1000 if timestamp >= 1_000_000_000_000
    timestamp
  end

  def contact_event_applicable?(current, event)
    current_timestamp = current['timestamp'].to_i
    return true if current_timestamp < event[:timestamp]
    return false if current_timestamp > event[:timestamp]

    event_keys = contact_event_keys(current)
    return false if event_keys.include?(event[:key])
    return :overflow if event_keys.size >= MAX_EVENT_KEYS_PER_TIMESTAMP

    true
  end

  def contact_event_keys_for_state(current, event)
    keys = current['timestamp'].to_i == event[:timestamp] ? contact_event_keys(current) : []
    (keys + [event[:key]]).uniq
  end

  def contact_event_keys(state)
    (Array(state['event_keys']) + [state['event_key']]).compact_blank.uniq
  end

  def update_sync_activity(entries)
    @channel.with_lock do
      entries.concat(reconcile_new_pending_events)
      config = @channel.reload.provider_config.deep_dup
      sync = config['coexistence_sync'].to_h
      sync['contacts_last_event_at'] = Time.current.iso8601
      sync['contacts_events_count'] = sync['contacts_events_count'].to_i + entries.size
      persist_pending_events!(sync)
      merge_quarantined_events!(sync)
      config['coexistence_sync'] = sync
      @channel.persist_provider_config_state!(config)
    end
  end

  def replay_pending_marketing_preference(contact_inbox)
    @channel.with_lock do
      config = @channel.reload.provider_config.deep_dup
      lifecycle_state = config['meta_webhook_lifecycle'].to_h
      service = Whatsapp::MarketingPreferenceService.new(channel: @channel, lifecycle_state: lifecycle_state)
      next if service.replay_for(contact_inbox) == :missing

      config['meta_webhook_lifecycle'] = lifecycle_state
      @channel.persist_provider_config_state!(config)
    end
  end

  def quarantine_event(entry, reason)
    safe_entry = Meta::CredentialDataSanitizer.sanitize(
      entry.to_h.deep_stringify_keys,
      secrets: Meta::CredentialDataSanitizer.channel_secrets(@channel)
    )
    key = Digest::SHA256.hexdigest({ reason: reason, entry: safe_entry }.to_json)
    @quarantined_events << { 'key' => key, 'reason' => reason }
  end

  def merge_quarantined_events!(sync)
    return if @quarantined_events.empty?

    new_events = unseen_quarantined_events(sync)
    update_quarantine_state!(sync, new_events)
  end

  def unseen_quarantined_events(sync)
    existing_keys = quarantine_keys(sync)
    @quarantined_events.uniq { |event| event['key'] }.reject { |event| existing_keys.include?(event['key']) }
  end

  def update_quarantine_state!(sync, new_events)
    existing_keys = quarantine_keys(sync)
    merged_keys = existing_keys + new_events.pluck('key')
    overflow = [merged_keys.size - MAX_QUARANTINED_EVENT_KEYS, 0].max
    sync.merge!(
      'contacts_quarantined_event_keys' => merged_keys.last(MAX_QUARANTINED_EVENT_KEYS),
      'contacts_quarantined_events_count' => sync['contacts_quarantined_events_count'].to_i + new_events.size,
      'contacts_quarantine_overflow_count' => sync['contacts_quarantine_overflow_count'].to_i + overflow,
      'contacts_state' => 'manual_recovery_required',
      'contacts_last_error' => @quarantined_events.last['reason']
    )
  end

  def quarantine_keys(sync) = Array(sync['contacts_quarantined_event_keys']).map(&:to_s)

  def normalize_phone(value)
    value.to_s.gsub(/\D/, '')
  end
end
