require 'digest'

# A Beeline channel has one SIP profile per operator. Every registered operator
# browser receives its own INVITE for the same external call and reports it as
# a leg of its own (its own SIP Call-ID, so its own call_ref). Without help the
# legs of one physical call look like unrelated calls: the claim and status
# broadcasts reach only one of them and the cards of the others stay.
#
# Beeline gives no identifier shared by the legs of one physical call, so the
# window and the caller are the only correlation. Two things keep a different
# call from being merged into a group: a leg dialled to another number is never
# a sibling, and a repeated leg of one operator profile (a profile gets one leg
# per call) starts a call of its own.
#
# Legs arrive within a few seconds of each other. A new leg joins the group of
# the oldest open leg of the same caller on the same channel by taking over its
# logical call key and group ref, which are what Telephony::CallSession::
# LogicalGrouping already reads. Callers hold Telephony::CallIntakeLock while
# they ask, so two legs arriving at the same instant end with the same key.
#
# Known limitation: Beeline gives the legs no identifier they share (call ids,
# provider sids and every event payload differ in all of them), so the caller
# number and the window are the whole correlation. Two live calls of the same
# caller number to the same channel within the window (two devices behind one
# caller ID) are one logical call until one of them ends; taking either one
# closes the legs of the other. A narrower rule would split the N legs of one
# call, which is the case that matters; see webphone_same_caller_calls_spec.
class Telephony::SiblingLegGrouping
  SIBLING_LEG_WINDOW = 20.seconds
  # Providers whose legs are per-operator browser registrations.
  PER_OPERATOR_LEG_PROVIDERS = %w[beeline].freeze
  KEY_PREFIX = 'native-sip-group'.freeze
  # A claim moves its leg to connecting, the answer to in_progress.
  OWNING_STATUSES = %w[connecting in_progress].freeze
  # Routing decisions for a leg that is reported after the call was taken. A
  # busy operator gets a reject (target_operator_busy) for a leg that is as
  # late as any other, so it is closed as well; only an AI decision keeps its
  # own handling.
  LATE_LEG_ACTIONS = %w[operator reject].freeze

  class << self
    def applies?(provider:, direction: 'inbound')
      direction.to_s == 'inbound' && provider.to_s.in?(PER_OPERATOR_LEG_PROVIDERS)
    end

    def late_leg_decision?(decision)
      (decision[:action] || decision['action']).to_s.in?(LATE_LEG_ACTIONS)
    end

    # The oldest leg of the physical call this leg belongs to; nil when this
    # leg is the first one. The leg itself may already exist (a retried report).
    # The destination and the operator profile of the new leg narrow the
    # candidates when they are known.
    def root_leg(number_binding:, caller_number:, call_ref:, destination_number: nil, operator_profile_id: nil, now: Time.current)
      digits = phone_digits(caller_number)
      return if digits.blank?

      legs = candidate_legs(number_binding, now).select do |leg|
        leg.external_call_ref == call_ref || sibling_candidate?(leg, digits, number_binding, destination_number)
      end
      legs = without_groups_of_profile(legs, call_ref, operator_profile_id)
      root = legs.min_by { |leg| [leg.created_at, leg.id] }
      root unless root&.external_call_ref == call_ref
    end

    # The open leg of the group that owns the call (its operator claimed or
    # answered it), nil while the call still rings for everybody. A leg that is
    # over owns nothing. `except` is a leg that is being admitted right now.
    def owner_leg(leg, except: nil)
      leg.logical_group_sessions.find { |candidate| candidate.id != except&.id && owning_leg?(candidate) }
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

    def owning_leg?(leg)
      !leg.terminal? && OWNING_STATUSES.include?(leg.canonical_status)
    end

    # A leg that is over never counts: a caller who hangs up and dials again
    # is not the same call, and a finished leg cannot answer for anybody.
    def sibling_candidate?(leg, digits, number_binding, destination_number)
      phone_digits(leg.from_number) == digits && !leg.terminal? &&
        same_number_binding?(leg, number_binding) && same_destination?(leg, destination_number)
    end

    def same_number_binding?(leg, number_binding)
      leg.number_binding_id.blank? || leg.number_binding_id == number_binding.id
    end

    # Unknown on either side does not exclude; a different number does.
    def same_destination?(leg, destination_number)
      wanted = destination_digits(destination_number)
      actual = destination_digits(leg.to_number)
      wanted.blank? || actual.blank? || wanted == actual
    end

    def destination_digits(value)
      phone_digits(value).last(10)
    end

    # A group that already has a leg of this operator profile is a call that
    # went to the profile already: a new leg of the profile is another call.
    def without_groups_of_profile(legs, call_ref, profile_id)
      return legs if profile_id.blank?

      others = legs.reject { |leg| leg.external_call_ref == call_ref }
      taken_groups = others.select { |leg| leg_profile_id(leg) == profile_id.to_s }.map(&:logical_call_group_ref)
      legs.reject { |leg| others.include?(leg) && taken_groups.include?(leg.logical_call_group_ref) }
    end

    def leg_profile_id(leg)
      route = leg.metadata.to_h['metadata']
      return unless route.is_a?(Hash)

      (route['target_sip_profile_id'].presence || route['telephony_sip_profile_id'].presence)&.to_s
    end
  end
end
