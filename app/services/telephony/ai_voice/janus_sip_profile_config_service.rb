# frozen_string_literal: true

require 'digest'

class Telephony::AiVoice::JanusSipProfileConfigService
  INACTIVE_STATUSES = %w[disabled deleting failed].freeze

  def perform
    profiles = active_voice_agent_profiles.filter_map { |profile| profile_payload(profile) }
    {
      version: config_version(profiles),
      profiles: profiles
    }
  end

  private

  def active_voice_agent_profiles
    Telephony::SipProfile
      .voice_agent
      .enabled
      .where.not(status: INACTIVE_STATUSES)
      .includes(:provider_connection, inbox: { telephony_number_binding: :routing_policy })
      .order(:account_id, :inbox_id, :id)
  end

  def profile_payload(profile)
    context = profile_context(profile)
    return unless registerable_profile?(profile, context)

    profile_identity_payload(profile, context)
      .merge(sip_connection_payload(profile, context))
      .merge(routing_payload(context[:routing_policy]))
      .compact
  end

  def profile_context(profile)
    binding = profile.inbox&.telephony_number_binding
    connection = profile.provider_connection || binding&.provider_connection
    connection_metadata = connection&.metadata.to_h.with_indifferent_access
    {
      binding: binding,
      connection: connection,
      routing_policy: binding&.routing_policy,
      sip_host: connection_metadata[:sip_domain].presence || profile.sip_host.presence || connection&.host,
      sip_proxy: connection_metadata[:outbound_proxy],
      sip_codec: connection_metadata[:codec],
      sip_password: profile.sip_password.presence
    }
  end

  def registerable_profile?(profile, context)
    profile.sip_username.present? && context[:sip_password].present? && context[:sip_host].present?
  end

  def profile_identity_payload(profile, context)
    binding = context[:binding]
    connection = context[:connection]
    {
      id: profile.id,
      version: profile.ensure_registration_config_version!,
      account_id: profile.account_id,
      inbox_id: profile.inbox_id,
      number_ref: binding&.number_ref,
      provider: binding&.provider || connection&.provider_kind,
      phone_number: binding&.phone_number,
      ingress_number: binding&.ingress_number,
      display_name: "OneLink AI #{profile.internal_extension}",
      internal_extension: profile.internal_extension,
      sip_profile: sip_profile_payload(profile)
    }
  end

  def sip_connection_payload(profile, context)
    connection = context[:connection]
    {
      sip_username: profile.sip_username,
      sip_password: context[:sip_password],
      sip_host: context[:sip_host],
      sip_port: connection&.port || 5060,
      sip_transport: connection&.transport.presence || 'udp',
      sip_proxy: context[:sip_proxy],
      sip_codec: context[:sip_codec]
    }
  end

  def routing_payload(routing_policy)
    {
      app_ref: routing_policy&.effective_ai_app_ref,
      routing_mode: routing_policy&.mode,
      fallback_mode: routing_policy&.fallback_mode
    }
  end

  def sip_profile_payload(profile)
    {
      id: profile.id,
      profile_kind: profile.profile_kind,
      voice_agent: true,
      internal_extension: profile.internal_extension,
      sip_username: profile.sip_username,
      agent_aor: profile.agent_aor,
      credentials_ref: profile.credentials_ref,
      registration_config_version: profile.registration_config_version
    }.compact
  end

  def config_version(profiles)
    Digest::SHA256.hexdigest(JSON.generate(profiles))
  end
end
