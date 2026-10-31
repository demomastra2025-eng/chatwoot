# frozen_string_literal: true

class Compliance::DeletedSubjectTombstone < ApplicationRecord
  HEX_HMAC_PATTERN = /\A[0-9a-f]{64}\z/

  belongs_to :account

  validates :identifier_kind, inclusion: { in: Compliance::TombstoneHasher::KINDS }
  validates :identifier_hmac, presence: true, format: { with: HEX_HMAC_PATTERN }
  validates :certificate_uid, presence: true
  validates :reason, presence: true
  validates :erased_at, presence: true

  scope :active, -> { where(revoked_at: nil) }

  class << self
    def table_ready?
      connection.data_source_exists?(table_name)
    rescue StandardError
      false
    end

    def blocked?(account_id:, identifiers:)
      entries = ready_entries(account_id, identifiers)
      return false if entries.empty?

      active_relation_for_entries(account_id, entries).exists?
    end

    def blocked_medelement_patient?(account_id:, patient: nil, patient_code: nil, reception: nil)
      return false if account_id.blank? || !table_ready?

      entries = Compliance::TombstoneHasher.extract_medelement_identifiers(
        account_id: account_id,
        patient: patient,
        patient_code: patient_code,
        reception: reception
      )
      blocked?(account_id: account_id, identifiers: entries)
    end

    # rubocop:disable Metrics/ParameterLists, Rails/SkipsModelValidations
    def upsert_entries!(account_id:, entries:, certificate_uid:, reason: 'subject_request', erased_at: Time.current,
                        remote_synced_at: nil, metadata: {})
      normalized = normalize_entries(account_id, entries)
      return [] if normalized.empty?

      rows = build_upsert_rows(
        normalized,
        account_id: account_id,
        certificate_uid: certificate_uid,
        reason: reason,
        erased_at: erased_at,
        remote_synced_at: remote_synced_at,
        metadata: metadata
      )
      upsert_all(
        rows,
        unique_by: :idx_compliance_tombstones_unique_lookup,
        update_only: %i[certificate_uid reason erased_at revoked_at remote_synced_at metadata]
      )
      where(account_id: account_id, certificate_uid: certificate_uid).to_a
    end
    # rubocop:enable Metrics/ParameterLists, Rails/SkipsModelValidations

    def revoke_for!(account_id:, identifiers:, sync_remote: true, revoked_at: nil)
      entries = ready_entries(account_id, identifiers)
      return 0 if entries.empty?

      effective_revoked_at = revoked_at || Time.current
      total = mark_entries_revoked!(account_id, entries, effective_revoked_at)
      sync_remote_revocation!(account_id, entries, effective_revoked_at) if sync_remote && total.positive?
      total
    end

    def normalize_entries(account_id, identifiers)
      case identifiers
      when Array then normalize_array_entries(identifiers)
      when Hash then Compliance::TombstoneHasher.build_entries(account_id, identifiers)
      else []
      end
    end

    private

    def ready_entries(account_id, identifiers)
      return [] if account_id.blank? || !table_ready?

      normalize_entries(account_id, identifiers)
    end

    def active_relation_for_entries(account_id, entries)
      hmacs_by_kind = entries.group_by { |e| e[:kind] }.transform_values { |list| list.pluck(:hmac).uniq }
      base = active.where(account_id: account_id)
      hmacs_by_kind.map { |kind, hmacs| base.where(identifier_kind: kind, identifier_hmac: hmacs) }.reduce(:or)
    end

    # rubocop:disable Metrics/ParameterLists
    def build_upsert_rows(normalized, account_id:, certificate_uid:, reason:, erased_at:, remote_synced_at:, metadata:)
      now = Time.current
      clean_reason = reason.to_s.presence || 'subject_request'
      normalized.map do |entry|
        {
          account_id: account_id,
          identifier_kind: entry[:kind],
          identifier_hmac: entry[:hmac],
          certificate_uid: certificate_uid,
          reason: clean_reason,
          erased_at: erased_at,
          revoked_at: nil,
          remote_synced_at: remote_synced_at,
          metadata: metadata.to_h,
          created_at: now,
          updated_at: now
        }
      end
    end
    # rubocop:enable Metrics/ParameterLists

    # rubocop:disable Rails/SkipsModelValidations
    def mark_entries_revoked!(account_id, entries, revoked_at)
      entries.group_by { |e| e[:kind] }.sum do |kind, list|
        active.where(
          account_id: account_id,
          identifier_kind: kind,
          identifier_hmac: list.pluck(:hmac)
        ).where('erased_at <= ?', revoked_at).update_all(revoked_at: revoked_at, updated_at: revoked_at)
      end
    end
    # rubocop:enable Rails/SkipsModelValidations

    def sync_remote_revocation!(account_id, entries, revoked_at)
      Compliance::TombstoneRemoteLedger.write_revocation!(
        account_id: account_id,
        entries: entries,
        revoked_at: revoked_at
      )
    end

    def normalize_array_entries(identifiers)
      identifiers.filter_map { |item| normalize_hash_entry(item) }.uniq
    end

    def normalize_hash_entry(item)
      return unless item.is_a?(Hash)

      kind = (item[:kind] || item['kind']).to_s
      hmac = (item[:hmac] || item['hmac']).to_s.downcase
      { kind: kind, hmac: hmac } if Compliance::TombstoneHasher::KINDS.include?(kind) && hmac.match?(HEX_HMAC_PATTERN)
    end
  end
end
