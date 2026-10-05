require 'digest'

# A Beeline channel has one SIP profile per operator. Every registered operator
# browser receives its own INVITE for the same external call and reports it as
# a leg of its own (its own SIP Call-ID, so its own call_ref). Without help the
# legs of one physical call look like unrelated calls: the claim and status
# broadcasts reach only one of them and the cards of the others stay.
#
# Legs arrive within a few seconds of each other. A new leg joins the group of
# the oldest leg of the same caller on the same channel by taking over its
# logical call key and group ref, which are what Telephony::CallSession::
# LogicalGrouping already reads. Callers hold Telephony::CallIntakeLock while
# they ask, so two legs arriving at the same instant end with the same key.
class Telephony::SiblingLegGrouping
  SIBLING_LEG_WINDOW = 20.seconds
  # A leg that is already over only counts when it was created this recently:
  # a caller who hangs up and dials again is not the same call.
  TERMINAL_SIBLING_WINDOW = 5.seconds
  # Providers whose legs are per-operator browser registrations.
  PER_OPERATOR_LEG_PROVIDERS = %w[beeline].freeze
  KEY_PREFIX = 'native-sip-group'.freeze

  class << self
    def applies?(provider:, direction: 'inbound')
      direction.to_s == 'inbound' && provider.to_s.in?(PER_OPERATOR_LEG_PROVIDERS)
    end

    # The oldest leg of the physical call this leg belongs to; nil when this
    # leg is the first one. The leg itself may already exist (a retried report).
    def root_leg(number_binding:, caller_number:, call_ref:, now: Time.current)
      digits = phone_digits(caller_number)
      return if digits.blank?

      legs = candidate_legs(number_binding, now).select do |leg|
        leg.external_call_ref == call_ref || sibling_candidate?(leg, digits, now)
      end
      root = legs.min_by { |leg| [leg.created_at, leg.id] }
      root unless root&.external_call_ref == call_ref
    end

    def group_key(root_leg)
      root_leg.logical_call_key.presence ||
        "#{KEY_PREFIX}:#{Digest::SHA256.hexdigest(root_leg.external_call_ref)[0, 32]}"
    end

    def group_ref(root_leg)
      root_leg.logical_call_group_ref.presence || root_leg.external_call_ref
    end

    def phone_digits(value)
      raw = value.to_s
      (raw[/\A<?sip:([^@;>]+)/i, 1] || raw).gsub(/\D/, '')
    end

    private

    def candidate_legs(number_binding, now)
      return [] if number_binding.inbox_id.blank?

      Telephony::CallSession.where(account_id: number_binding.account_id, inbox_id: number_binding.inbox_id,
                                   provider: number_binding.provider, direction: 'inbound')
                            .where(created_at: (now - SIBLING_LEG_WINDOW)..)
                            .where.not('external_call_ref LIKE ?', '%:janus-server:%')
                            .to_a
    end

    def sibling_candidate?(leg, digits, now)
      return false unless phone_digits(leg.from_number) == digits

      !leg.terminal? || leg.created_at >= now - TERMINAL_SIBLING_WINDOW
    end
  end
end
