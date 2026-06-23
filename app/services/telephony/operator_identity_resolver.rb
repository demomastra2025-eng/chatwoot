# frozen_string_literal: true

class Telephony::OperatorIdentityResolver
  Identity = Struct.new(:source, :record, keyword_init: true) do
    def agent_binding
      record if source == :agent_binding
    end

    def sip_profile
      record if source == :sip_profile
    end

    def agent_ref
      agent_binding&.agent_ref || sip_profile&.fonoster_agent_ref.presence || sip_profile&.agent_ref
    end

    def agent_aor
      agent_binding&.agent_aor || sip_profile&.agent_aor
    end

    def provider
      agent_binding&.provider || 'fonoster'
    end

    def enabled?
      agent_binding ? agent_binding.enabled? : sip_profile&.enabled?
    end

    def browser_join_supported?
      return true if agent_binding

      sip_profile&.availability_mode == 'browser_webphone'
    end

    def metadata
      attrs = {
        operator_identity_source: source.to_s,
        operator_agent_ref: agent_ref,
        operatorAgentRef: agent_ref,
        fonoster_agent_ref: agent_ref,
        fonosterAgentRef: agent_ref,
        operator_agent_aor: agent_aor,
        operatorAgentAor: agent_aor,
        agent_aor: agent_aor,
        agentAor: agent_aor,
        browser_join_supported: browser_join_supported?
      }

      if sip_profile
        attrs.merge!(
          sip_profile_id: sip_profile.id,
          operator_identity_availability_mode: sip_profile.availability_mode,
          internal_extension: sip_profile.internal_extension
        )
      end

      attrs.compact
    end
  end

  def initialize(account:, inbox:, user:)
    @account = account
    @inbox = inbox
    @user = user
  end

  def resolve
    sip_profile_identity || agent_binding_identity
  end

  private

  attr_reader :account, :inbox, :user

  def sip_profile_identity
    profile = sip_profile_scope.first
    return if profile.blank?

    Identity.new(source: :sip_profile, record: profile)
  end

  def sip_profile_scope
    return Telephony::SipProfile.none if user.blank?

    scope = if inbox.present? && inbox.respond_to?(:telephony_sip_profiles)
              inbox.telephony_sip_profiles
            elsif inbox.present?
              account.telephony_sip_profiles.where(inbox_id: inbox.id)
            else
              account.telephony_sip_profiles.where(availability_mode: 'browser_webphone')
            end

    scope.where(user_id: user.id, enabled: true)
         .where.not(status: %w[disabled deleting failed])
         .order(Arel.sql("CASE availability_mode WHEN 'browser_webphone' THEN 0 ELSE 1 END"), updated_at: :desc, id: :desc)
  end

  def agent_binding_identity
    return if managed_number_binding?

    binding = account.telephony_agent_bindings.enabled.find_by(user_id: user&.id)
    return if binding.blank?

    Identity.new(source: :agent_binding, record: binding)
  end

  def managed_number_binding?
    number_binding&.managed?
  end

  def number_binding
    return @number_binding if defined?(@number_binding)

    @number_binding = if inbox.respond_to?(:telephony_number_binding)
                        inbox.telephony_number_binding
                      elsif inbox.present?
                        Telephony::NumberBinding.find_by(account_id: account.id, inbox_id: inbox.id)
                      end
  end
end
