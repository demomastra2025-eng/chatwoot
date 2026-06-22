# frozen_string_literal: true

class Telephony::VirtualPbx::DesiredStateBuilder
  MANAGED_BY_ONELINK = 'onelink'

  def initialize(account:)
    @account = account
    @config_builder = Telephony::VirtualPbx::ConfigBuilder.new(account: account)
  end

  def for_inbox(inbox_or_id)
    config = config_builder.for_inbox(inbox_or_id).with_indifferent_access
    inbox = account.inboxes.find(config[:inbox_id])
    binding = inbox.telephony_number_binding
    provider_connection = binding&.provider_connection
    resources = (config[:resources] || {}).with_indifferent_access
    phone_numbers = (config[:phone_numbers] || {}).with_indifferent_access
    routing = (config[:routing] || {}).with_indifferent_access

    sanitize(
      account_id: account.id,
      inbox_id: inbox.id,
      channel_id: config[:channel_id],
      provider: config[:provider],
      provider_kind: config[:provider_kind],
      managed_by: MANAGED_BY_ONELINK,
      name: config[:name],
      phone_numbers: {
        display_phone_number: phone_numbers[:display_phone_number],
        provider_account_number: phone_numbers[:provider_account_number],
        ingress_number: phone_numbers[:ingress_number],
        fonoster_tel_url: phone_numbers[:fonoster_tel_url]
      }.compact,
      refs: refs_payload(resources, provider_connection),
      connection: connection_payload(provider_connection),
      routing: routing_payload(routing, binding),
      profiles: profiles_payload(config[:profiles]),
      ownership: ownership_payload(config, binding),
      resources: {
        number_binding_id: resources[:number_binding_id],
        provider_connection_id: resources[:provider_connection_id]
      }.compact
    ).deep_symbolize_keys
  end

  private

  attr_reader :account, :config_builder

  def refs_payload(resources, provider_connection)
    {
      number_ref: resources[:number_ref],
      trunk_ref: resources[:trunk_ref] || provider_connection&.fonoster_trunk_ref,
      credentials_ref: provider_connection&.credentials_ref || provider_connection&.fonoster_credentials_ref,
      app_ref: resources[:app_ref],
      runtime_app_ref: resources[:runtime_app_ref]
    }.compact
  end

  def connection_payload(provider_connection)
    return {} if provider_connection.blank?

    {
      provider_kind: provider_connection.provider_kind,
      name: provider_connection.name,
      host: provider_connection.host,
      port: provider_connection.port,
      transport: provider_connection.transport,
      username: provider_connection.username,
      send_register: provider_connection.send_register,
      credentials_ref: provider_connection.credentials_ref || provider_connection.fonoster_credentials_ref,
      fonoster_credentials_ref: provider_connection.fonoster_credentials_ref,
      password_configured: provider_connection.password_secret_ref.present?
    }.compact
  end

  def routing_payload(routing, binding)
    {
      mode: routing[:mode],
      bridge_mode: routing[:bridge_mode],
      fallback_mode: routing[:fallback_mode],
      operator_distribution_mode: routing[:operator_distribution_mode],
      app_ref: binding&.app_ref_for_policy(binding&.routing_policy),
      operator_agent_ref: routing[:operator_agent_ref],
      operator_target_configured: routing[:operator_agent_aor].present? || routing[:operator_agent_ref].present?,
      ai_enabled: routing[:ai_enabled],
      ai_app_ref: routing[:ai_app_ref]
    }.compact
  end

  def profiles_payload(profiles)
    Array.wrap(profiles).map do |profile|
      attrs = profile.with_indifferent_access
      {
        id: attrs[:id],
        user_id: attrs[:user_id],
        user_name: attrs[:user_name],
        provider_connection_id: attrs[:provider_connection_id],
        internal_extension: attrs[:internal_extension],
        sip_username: attrs[:sip_username],
        sip_host: attrs[:sip_host],
        credentials_ref: attrs[:credentials_ref],
        fonoster_credentials_ref: attrs[:fonoster_credentials_ref],
        local_agent_ref: attrs[:agent_ref],
        agent_ref: attrs[:fonoster_agent_ref].presence || attrs[:agent_ref],
        fonoster_agent_ref: attrs[:fonoster_agent_ref],
        agent_aor: attrs[:agent_aor],
        availability_mode: attrs[:availability_mode],
        status: attrs[:status],
        access_configured: attrs[:sip_password_configured] || attrs[:credentials_ref].present?,
        enabled: attrs[:enabled]
      }.compact
    end
  end

  def ownership_payload(config, binding)
    ownership = (config[:ownership] || {}).with_indifferent_access
    {
      managed_by: ownership[:managed_by] || binding&.managed_by,
      ownership_status: ownership[:ownership_status] || binding&.ownership_status,
      read_only: ownership[:read_only],
      onelink_account_id: account.id,
      onelink_inbox_id: config[:inbox_id],
      onelink_channel_id: config[:channel_id],
      onelink_number_binding_id: binding&.id
    }.compact
  end

  def sanitize(value)
    Telephony::VirtualPbx::ConfigBuilder.sanitize(value)
  end
end
