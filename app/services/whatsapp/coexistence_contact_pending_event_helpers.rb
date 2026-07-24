module Whatsapp::CoexistenceContactPendingEventHelpers
  include Whatsapp::CoexistenceContactPendingEventPersistence

  MAX_PENDING_CONTACT_EVENTS = 50
  LEDGER_UNIQUE_INDEX = 'idx_wa_coex_contact_pending_channel_event'.freeze

  private

  def load_pending_events
    legacy_events = legacy_pending_events.index_by { |event| event['key'] }
    records = pending_event_records
    record_events = records.index_by(&:event_key).transform_values(&:ledger_payload)

    @legacy_pending_events = legacy_events.except(*record_events.keys)
    @pending_events = @legacy_pending_events.merge(record_events)
    @new_pending_events = {}
    @resolved_pending_event_keys = []
    @pending_page_last_id = records.last&.id
  end

  def replay_pending_entries
    @pending_events.values.filter_map do |event|
      entry = event['entry'].to_h.with_indifferent_access
      entry if apply_entry(entry)
    end
  end

  def pend_contact_event(entry, event)
    safe_entry = Meta::CredentialDataSanitizer.sanitize(
      entry.to_h.deep_stringify_keys,
      secrets: Meta::CredentialDataSanitizer.channel_secrets(@channel)
    )
    pending_event = {
      'key' => event[:key],
      'reason' => 'missing_contact_identity',
      'phone_identity' => canonical_phone_identity(safe_entry.dig('contact', 'phone_number')),
      'entry' => safe_entry
    }
    @pending_events[event[:key]] = pending_event
    @new_pending_events[event[:key]] = pending_event
  end

  def legacy_pending_events
    Array(@channel.reload.provider_config.dig('coexistence_sync', 'contacts_pending_events'))
      .map(&:to_h)
      .select { |event| event['key'].present? && event['entry'].present? }
  end

  def pending_event_records
    @pending_until_id ||= pending_event_scope.maximum(:id)
    return [] if @pending_until_id.blank?

    scope = pending_event_scope.where(id: ..@pending_until_id).order(:id)
    scope = scope.where('id > ?', @pending_after_id) if @pending_after_id.present?
    scope.limit(MAX_PENDING_CONTACT_EVENTS).to_a
  end

  def pending_event_scope
    Whatsapp::CoexistenceContactPendingEvent.where(account_id: @channel.account_id, channel_id: @channel.id)
  end

  def clear_pending_event(key)
    @pending_events.delete(key)
    @new_pending_events.delete(key)
    @resolved_pending_event_keys << key
  end

  def reconcile_new_pending_events
    @new_pending_events.values.filter_map do |event|
      entry = event['entry'].to_h.deep_symbolize_keys
      entry if apply_entry(entry)
    end
  end

  def pending_event_phone_identity(event)
    event['phone_identity'].presence || canonical_phone_identity(event.dig('entry', 'contact', 'phone_number'))
  end

  def canonical_phone_identity(phone_number)
    Whatsapp::PhoneNumberNormalizationService.new(@channel.inbox).canonical_source_id(phone_number, :cloud)
  end
end
