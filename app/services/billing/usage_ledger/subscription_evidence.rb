# frozen_string_literal: true

require 'digest'
require 'json'
require 'time'

# Internal, exact-event evidence. A month anchor never proves event entitlement.
class Billing::UsageLedger::SubscriptionEvidence
  CORE_KEYS = %w[at bucket period_id quantity subscription_id workspace_id].freeze
  PROOF_KEYS = %w[account_id billing_account_id cycle_ends_at cycle_starts_at event_id source_digest status subscription_created_at version].freeze

  def self.capture(event:, source:, subscription:, payer_id:)
    starts_at = subscription.current_period_starts_at
    ends_at = subscription.current_period_ends_at
    raise Billing::UsageLedger::Refused, :subscription_interval_unproved unless current_cycle_covers?(subscription, event.occurred_at)

    proof = { 'version' => 1, 'event_id' => event.id, 'account_id' => event.account_id, 'billing_account_id' => payer_id,
              'status' => subscription.status, 'subscription_created_at' => subscription.created_at.utc.iso8601(6),
              'cycle_starts_at' => starts_at.utc.iso8601(6), 'cycle_ends_at' => ends_at.utc.iso8601(6),
              'source_digest' => source_digest(event.id, event.account_id, source) }
    source.merge('subscription_evidence' => proof)
  end

  def self.current_cycle_covers?(subscription, event_at)
    created_at = subscription.created_at
    starts_at = subscription.current_period_starts_at
    ends_at = subscription.current_period_ends_at
    BillingSubscription::ENTITLING_STATUSES.include?(subscription.status) && [created_at, starts_at, ends_at].all? &&
      created_at <= event_at && starts_at <= event_at && event_at < ends_at
  end
  private_class_method :current_cycle_covers?

  def self.valid?(source, event_id:, account_id:)
    proof = source['subscription_evidence']
    return false unless proof_shape?(proof) && proof_identity?(proof, event_id, account_id)
    return false unless BillingSubscription::ENTITLING_STATUSES.include?(proof['status'])
    return false unless proof['source_digest'] == source_digest(proof['event_id'], account_id, source)

    covered?(source, proof)
  end

  def self.proof_shape?(proof)
    proof.is_a?(Hash) && proof.keys.all?(String) && proof.keys.sort == PROOF_KEYS && proof['version'].eql?(1)
  end
  private_class_method :proof_shape?

  def self.proof_identity?(proof, event_id, account_id)
    positive_ids = %w[event_id account_id billing_account_id].all? { |key| proof[key].is_a?(Integer) && proof[key].positive? }
    positive_ids && proof['event_id'].to_s == event_id.to_s && proof['account_id'] == account_id
  end
  private_class_method :proof_identity?

  def self.covered?(source, proof)
    event_at, created_at, starts_at, ends_at = [source['at'], proof['subscription_created_at'], proof['cycle_starts_at'],
                                                proof['cycle_ends_at']].map { |value| timestamp(value) }
    [event_at, created_at, starts_at, ends_at].all? && created_at <= event_at && starts_at <= event_at && event_at < ends_at
  end
  private_class_method :covered?

  def self.timestamp(value)
    return unless value.is_a?(String)

    parsed = Time.iso8601(value)
    parsed if parsed.utc.iso8601(6) == value
  rescue ArgumentError
    nil
  end
  private_class_method :timestamp

  def self.source_digest(event_id, account_id, source)
    Digest::SHA256.hexdigest(JSON.generate([event_id, account_id, source.slice(*CORE_KEYS).sort]))
  end
  private_class_method :source_digest
end
