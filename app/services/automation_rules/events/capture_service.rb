class AutomationRules::Events::CaptureService
  SCHEMA_VERSION = 1

  class << self
    def capture!(**envelope)
      account = envelope.fetch(:account)
      subject = envelope.fetch(:subject)
      dedupe_key = envelope.fetch(:dedupe_key)
      validate_envelope!(account, subject, envelope[:causation_event])

      existing = AutomationEvent.find_by(account_id: account.id, dedupe_key: dedupe_key)
      return existing if existing.present?

      AutomationEvent.transaction(requires_new: true) { AutomationEvent.create!(event_attributes(envelope)) }
    rescue ActiveRecord::RecordNotUnique
      AutomationEvent.find_by!(account_id: account.id, dedupe_key: dedupe_key)
    rescue ActiveRecord::RecordInvalid => e
      dedupe_conflict = e.record.errors.details.fetch(:dedupe_key, []).any? { |error| error[:error] == :taken }
      raise unless dedupe_conflict

      AutomationEvent.find_by!(account_id: account.id, dedupe_key: dedupe_key)
    end

    def capture_model_event!(record:, event_name:, payload_snapshot:, producer:, changes_snapshot: {})
      normalized_changes = json_object(changes_snapshot)
      normalized_payload = json_object(payload_snapshot)
      capture!(
        account: record.account,
        event_name: normalize_event_name(event_name),
        subject: record,
        payload_snapshot: normalized_payload,
        changes_snapshot: normalized_changes,
        producer: producer,
        provenance: model_provenance(record.account),
        dedupe_key: model_dedupe_key(record, event_name, normalized_payload, normalized_changes)
      )
    end

    private

    def event_attributes(envelope)
      account = envelope.fetch(:account)
      subject = envelope.fetch(:subject)
      dedupe_key = envelope.fetch(:dedupe_key)
      causation_event = envelope[:causation_event]

      {
        account: account,
        event_name: envelope.fetch(:event_name),
        subject_type: subject.class.base_class.name,
        subject_id: subject.id,
        schema_version: SCHEMA_VERSION,
        payload_snapshot: json_object(envelope.fetch(:payload_snapshot)),
        changes_snapshot: json_object(envelope[:changes_snapshot] || {}),
        producer: envelope.fetch(:producer),
        provenance: json_object(envelope.fetch(:provenance)),
        dedupe_key: dedupe_key
      }.merge(causation_attributes(account, dedupe_key, causation_event))
    end

    def causation_attributes(account, dedupe_key, causation_event)
      {
        trace_id: causation_event&.trace_id || deterministic_uuid(account.id, dedupe_key),
        causation_event: causation_event,
        causation_id: causation_event&.event_uuid,
        depth: causation_event ? causation_event.depth + 1 : 0
      }
    end

    def validate_envelope!(account, subject, causation_event)
      raise ArgumentError, 'subject must be persisted' unless subject.is_a?(ApplicationRecord) && subject.persisted?
      raise ArgumentError, 'subject must belong to the account' unless subject.respond_to?(:account_id) && subject.account_id == account.id
      return if causation_event.blank? || causation_event.account_id == account.id

      raise ArgumentError, 'causation event must belong to the account'
    end

    def normalize_event_name(event_name)
      event_name.to_s.tr('.', '_')
    end

    def model_dedupe_key(record, event_name, payload_snapshot, changes_snapshot)
      occurred_at = record.updated_at || record.created_at
      raise ArgumentError, 'record timestamp is required' if occurred_at.blank?

      occurrence_fingerprint = Digest::SHA256.hexdigest(
        JSON.generate(canonical_json(payload: payload_snapshot, changes: changes_snapshot))
      )

      [
        'model-v1',
        record.class.base_class.name.underscore,
        record.id,
        normalize_event_name(event_name),
        occurred_at.utc.iso8601(6),
        occurrence_fingerprint
      ].join(':')
    end

    def canonical_json(value)
      case value
      when Hash
        value.to_h.transform_keys(&:to_s).sort.to_h.transform_values { |nested| canonical_json(nested) }
      when Array
        value.map { |nested| canonical_json(nested) }
      else
        value
      end
    end

    def model_provenance(account)
      actor = Current.executed_by
      actor = nil unless trusted_actor_for_account?(actor, account)

      {
        'source' => 'model_callback',
        'actor_type' => actor&.class&.base_class&.name || 'System',
        'actor_id' => actor&.id
      }.compact
    end

    def trusted_actor_for_account?(actor, account)
      return false unless actor.is_a?(ApplicationRecord) && actor.persisted?
      return actor.account_id == account.id if actor.respond_to?(:account_id)

      actor.is_a?(User) && account.users.exists?(id: actor.id)
    end

    def deterministic_uuid(account_id, dedupe_key)
      hex = Digest::SHA256.hexdigest("automation-event:#{account_id}:#{dedupe_key}").first(32)
      [hex[0, 8], hex[8, 4], hex[12, 4], hex[16, 4], hex[20, 12]].join('-')
    end

    def json_object(value)
      value.to_h.deep_stringify_keys.as_json
    end
  end
end
