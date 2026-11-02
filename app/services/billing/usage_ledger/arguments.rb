# frozen_string_literal: true

class Billing::UsageLedger::Arguments
  KEYS = %i[account_id event_ids provenance expected_version contact_id merge_from baseline].freeze
  PROOF_KEYS = %i[period_id subscription_id workspace_id].freeze
  attr_reader(*KEYS)

  def initialize(**values)
    values = { contact_id: nil, merge_from: {}, baseline: nil }.merge(values)
    raise Billing::UsageLedger::Refused, :invalid_input unless values.keys.all?(Symbol) && values.keys.sort == KEYS.sort

    KEYS.each { |key| instance_variable_set("@#{key}", values[key]) }
    validate!
  end

  private

  def positive?(value)
    value.is_a?(Integer) && value.positive?
  end

  def valid_context?
    positive?(account_id) && (contact_id.nil? || positive?(contact_id)) && expected_version.is_a?(Integer) && expected_version >= 0
  end

  def validate!
    raise Billing::UsageLedger::Refused, :invalid_input unless valid_context?

    validate_event_ids!
    raise Billing::UsageLedger::Refused, :provenance_missing unless valid_provenance?

    validate_merge!
  end

  def validate_event_ids!
    valid_events = event_ids.is_a?(Array) && event_ids.all? { |id| positive?(id) }
    raise Billing::UsageLedger::Refused, :invalid_input unless valid_events
    raise Billing::UsageLedger::Refused, :source_missing if event_ids.empty?
    raise Billing::UsageLedger::Refused, :duplicate_source unless event_ids.uniq == event_ids
  end

  def validate_merge!
    valid_merge = merge_from.is_a?(Hash) && merge_from.all? { |id, version| positive?(id) && positive?(version) }
    raise Billing::UsageLedger::Refused, :invalid_merge unless valid_merge
  end

  def valid_provenance?
    valid_keys = provenance.is_a?(Hash) && provenance.keys.all? { |id| positive?(id) }
    valid_keys && provenance.keys.sort == event_ids.sort && provenance.values.all? { |value| valid_proof?(value) }
  end

  def valid_proof?(value)
    value.is_a?(Hash) && value.keys.all?(Symbol) && value.keys.sort == PROOF_KEYS && value.values.all? { |id| positive?(id) }
  end
end
