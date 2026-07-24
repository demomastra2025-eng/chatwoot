module Whatsapp::CoexistenceContactPendingEventPersistence
  private

  def persist_pending_events!(sync)
    delete_resolved_pending_events!
    insert_pending_events!(sync)
    refresh_pending_event_state!(sync)
    prepare_pending_reconciliation
  end

  def delete_resolved_pending_events!
    return if @resolved_pending_event_keys.empty?

    pending_event_scope.where(event_key: @resolved_pending_event_keys).delete_all
  end

  def insert_pending_events!(sync)
    events = pending_events_to_insert(sync)
    return if events.empty?

    timestamp = Time.current
    rows = events.map { |event| pending_event_row(event, timestamp) }
    # The unique ledger index provides idempotency; payloads are already sanitized and tenant-scoped.
    # rubocop:disable Rails/SkipsModelValidations
    Whatsapp::CoexistenceContactPendingEvent.insert_all(
      rows,
      unique_by: Whatsapp::CoexistenceContactPendingEventHelpers::LEDGER_UNIQUE_INDEX
    )
    # rubocop:enable Rails/SkipsModelValidations
  end

  def pending_event_row(event, timestamp)
    {
      account_id: @channel.account_id,
      channel_id: @channel.id,
      event_key: event['key'],
      reason: event['reason'],
      phone_identity: pending_event_phone_identity(event),
      entry: event['entry'].to_h,
      created_at: timestamp,
      updated_at: timestamp
    }
  end

  def pending_events_to_insert(sync)
    current_legacy = Array(sync['contacts_pending_events']).map(&:to_h).index_by { |event| event['key'] }
    legacy = current_legacy.slice(*@legacy_pending_events.keys)
    events = legacy.merge(@new_pending_events)
    events.except(*@resolved_pending_event_keys).values
  end

  def refresh_pending_event_state!(sync)
    records = pending_event_scope.order(:id).limit(max_pending_contact_events).to_a
    total = pending_event_scope.count
    clear_legacy_pending_overflow!(sync)
    persist_pending_event_state!(sync, records.map(&:ledger_payload), total)
  end

  def persist_pending_event_state!(sync, events, total)
    if total.zero?
      clear_pending_event_state!(sync)
    else
      sync['contacts_pending_events'] = events
      sync['contacts_pending_events_count'] = total
      persist_pending_archive_count!(sync, total - events.size)
      sync['contacts_state'] = 'pending_replay' unless sync['contacts_state'] == 'manual_recovery_required'
    end
  end

  def persist_pending_archive_count!(sync, archive_count)
    if archive_count.positive?
      sync['contacts_pending_archive_count'] = archive_count
    else
      sync.delete('contacts_pending_archive_count')
    end
  end

  def clear_pending_event_state!(sync)
    sync.delete('contacts_pending_events')
    sync.delete('contacts_pending_events_count')
    sync.delete('contacts_pending_archive_count')
    sync['contacts_state'] = 'active' if sync['contacts_state'] == 'pending_replay'
  end

  def clear_legacy_pending_overflow!(sync)
    sync.delete('contacts_pending_overflow_count')
    return unless sync['contacts_last_error'] == 'pending_event_overflow'

    sync.delete('contacts_last_error')
    sync['contacts_state'] = 'pending_replay'
  end

  def prepare_pending_reconciliation
    return if @pending_page_last_id.blank? || @pending_until_id.blank?
    return unless @pending_page_last_id < @pending_until_id

    @pending_reconciliation_arguments = [@channel.id, @pending_page_last_id, @pending_until_id]
  end

  def enqueue_pending_event_reconciliation
    return if @pending_reconciliation_arguments.blank?

    Whatsapp::CoexistenceContactPendingEventReconciliationJob.perform_later(*@pending_reconciliation_arguments)
  end

  def max_pending_contact_events
    Whatsapp::CoexistenceContactPendingEventHelpers::MAX_PENDING_CONTACT_EVENTS
  end
end
