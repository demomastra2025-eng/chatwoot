class AutomationRules::Events::CaptureService
  SCHEMA_VERSION = 1
  DUPLICATE_LOOKUP_ATTEMPTS = 3
  DUPLICATE_LOOKUP_DELAY = 0.01.seconds

  class << self
    def capture!(**envelope)
      account = envelope.fetch(:account)
      subject = envelope.fetch(:subject)
      dedupe_key = envelope.fetch(:dedupe_key)
      validate_envelope!(account, subject, envelope[:causation_event])

      existing = find_existing(account.id, dedupe_key)
      return existing if existing.present?

      AutomationEvent.transaction(requires_new: true) { AutomationEvent.create!(event_attributes(envelope)) }
    rescue ActiveRecord::RecordNotUnique
      find_duplicate_winner!(account.id, dedupe_key)
    rescue ActiveRecord::RecordInvalid => e
      raise unless duplicate_only_error?(e.record.errors)

      find_duplicate_winner!(account.id, dedupe_key)
    end

    def capture_model_event!(record:, event_name:, payload_snapshot:, producer:, **options)
      occurrence_id = options.fetch(:occurrence_id)
      changes_snapshot = options.fetch(:changes_snapshot, {})
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
        dedupe_key: model_dedupe_key(record, event_name, occurrence_id)
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

    def model_dedupe_key(record, event_name, occurrence_id)
      raise ArgumentError, 'occurrence id is required' if occurrence_id.blank?

      [
        'model-v2',
        record.class.base_class.name.underscore,
        record.id,
        normalize_event_name(event_name),
        occurrence_id
      ].join(':')
    end

    def find_existing(account_id, dedupe_key)
      ApplicationRecord.uncached do
        AutomationEvent.find_by(account_id: account_id, dedupe_key: dedupe_key)
      end
    end

    def find_duplicate_winner!(account_id, dedupe_key)
      DUPLICATE_LOOKUP_ATTEMPTS.times do |attempt|
        winner = find_existing(account_id, dedupe_key)
        return winner if winner.present?

        sleep(DUPLICATE_LOOKUP_DELAY) if attempt < DUPLICATE_LOOKUP_ATTEMPTS - 1
      end

      raise ActiveRecord::RecordNotFound, "AutomationEvent winner is not visible for #{dedupe_key}"
    end

    def duplicate_only_error?(errors)
      return false unless errors.attribute_names == [:dedupe_key]

      details = errors.details.fetch(:dedupe_key, [])
      details.present? && details.all? { |error| error[:error] == :taken }
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
