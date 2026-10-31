# frozen_string_literal: true

# Replays external ps.kz S3 tombstone ledger files in strict chronological order after a
# PostgreSQL backup restore and re-purges any Contact rows resurrected from an older snapshot.
class Compliance::TombstoneReplayService
  def initialize(account:, records: nil)
    @account = account
    @records = records
  end

  def perform!
    ledger_records = Array(@records || Compliance::TombstoneRemoteLedger.list_account_records(account.id))
    replayed_erasures, replayed_revocations = replay_chronologically!(ledger_records)
    purged_contacts = purge_resurrected_contacts!

    {
      account_id: account.id,
      replayed_erasures: replayed_erasures,
      replayed_revocations: replayed_revocations,
      purged_resurrected_contacts: purged_contacts
    }
  end

  private

  attr_reader :account

  def replay_chronologically!(records)
    erasures = 0
    revocations = 0
    sorted = records.each_with_index.sort_by { |rec, idx| [event_timestamp(rec), idx] }.map(&:first)

    sorted.each do |rec|
      if rec['type'].to_s == 'revocation'
        revocations += apply_revocation_event!(rec)
      elsif apply_erasure_event!(rec)
        erasures += 1
      end
    end
    [erasures, revocations]
  end

  def event_timestamp(rec)
    parse_time(rec['erased_at'] || rec['revoked_at']) || Time.at(0).utc
  end

  def apply_erasure_event!(rec)
    entries = extract_entries(rec)
    return false if entries.empty?

    erased_at = parse_time(rec['erased_at']) || Time.current
    fresh_entries = filter_non_stale_entries(entries, erased_at)
    return false if fresh_entries.empty?

    Compliance::DeletedSubjectTombstone.upsert_entries!(
      account_id: account.id,
      entries: fresh_entries,
      certificate_uid: rec['certificate_uid'].to_s.presence || "REPLAY-#{erased_at.to_i}",
      reason: rec['reason'].to_s.presence || 'ledger_replay',
      erased_at: erased_at,
      remote_synced_at: Time.current,
      metadata: rec['metadata'].to_h
    )
    true
  end

  def filter_non_stale_entries(entries, incoming_erased_at)
    normalized = Compliance::DeletedSubjectTombstone.normalize_entries(account.id, entries)
    existing_by_key = Compliance::DeletedSubjectTombstone
                      .where(account_id: account.id, identifier_hmac: normalized.pluck(:hmac))
                      .index_by { |row| [row.identifier_kind, row.identifier_hmac] }

    normalized.reject do |entry|
      row = existing_by_key[[entry[:kind], entry[:hmac]]]
      row && ((row.erased_at && row.erased_at > incoming_erased_at) || (row.revoked_at && row.revoked_at > incoming_erased_at))
    end
  end

  def apply_revocation_event!(rec)
    entries = extract_entries(rec)
    return 0 if entries.empty?

    revoked_at = parse_time(rec['revoked_at']) || Time.current
    Compliance::DeletedSubjectTombstone.revoke_for!(
      account_id: account.id,
      identifiers: entries,
      sync_remote: false,
      revoked_at: revoked_at
    )
  end

  def extract_entries(rec)
    Array(rec['entries']).map { |e| { kind: e['kind'] || e[:kind], hmac: e['hmac'] || e[:hmac] } }
  end

  def purge_resurrected_contacts!
    purged = 0
    account.contacts.find_each do |contact|
      entries = Compliance::TombstoneHasher.extract_contact_identifiers(contact)
      next unless Compliance::DeletedSubjectTombstone.blocked?(account_id: account.id, identifiers: entries)

      Compliance::SubjectErasureService.new(
        account: account,
        contact: contact,
        reason: 'post_restore_tombstone_replay'
      ).perform!
      purged += 1
    end
    purged
  end

  def parse_time(raw)
    Time.zone.parse(raw.to_s) if raw.present?
  rescue ArgumentError, TypeError
    nil
  end
end
