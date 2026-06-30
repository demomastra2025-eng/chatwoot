# frozen_string_literal: true

require 'cgi'
require 'uri'

class Telephony::VirtualPbx::RemotePlanBuilder
  REMOTE_MUTATIONS_BLOCKED = 'blocked'
  REMOTE_MUTATIONS_REQUIRES_APPROVAL = 'requires_approval'
  DEFAULT_SIPUNI_TRUNK_REF = 'trunk-sipuni-onelink-out'
  PROVIDER_OWNED_ROUTING_KINDS = %w[sipuni binotel].freeze
  PROVIDER_EXTENSION_MODES = %w[external_extension provider_extension].freeze

  def initialize(account:)
    @account = account
    @ownership_policy = Telephony::VirtualPbx::OwnershipPolicy.new(account: account)
  end

  def build(operation:, desired_state:, remote_actual: nil)
    state = desired_state.with_indifferent_access
    ownership = ownership_policy.check!(operation: operation, desired_state: state)
    operations = operations_for(operation, state, ownership)
    operations = apply_remote_actual_conflicts(operations, remote_actual) if remote_actual.present?

    {
      operation: operation,
      status: plan_status(operations, ownership),
      remote_mutations: remote_mutation_status(ownership),
      operations: operations,
      conflicts: operations.filter_map { |item| item[:conflict] },
      generated_at: Time.current
    }
  end

  private

  attr_reader :account, :ownership_policy

  def operations_for(operation, state, ownership)
    return [] if local_native_provider?(state)

    case operation.to_s
    when 'delete'
      delete_operations(state, ownership)
    when 'update', 'reconcile'
      update_operations(state, ownership)
    else
      create_operations(state, ownership)
    end
  end

  def create_operations(state, ownership)
    refs = state[:refs] || {}
    [
      connection_credentials_operation(state, ownership),
      *profile_credentials_operations(state, ownership),
      trunk_operation(state, ownership, 'Prepare provider connection for inbound calls'),
      operation_payload('upsert_number', 'PUT', path('numbers', refs[:number_ref]), 'Connect the business number to OneLink runtime', ownership,
                        payload: number_payload(state)),
      operation_payload('update_number_route', 'POST', "#{path('numbers', refs[:number_ref])}/route", 'Apply selected routing mode', ownership,
                        payload: route_payload(state)),
      *agent_assignment_operations(state, ownership)
    ].compact
  end

  def update_operations(state, ownership)
    refs = state[:refs] || {}
    [
      *stale_profile_cleanup_operations(state, ownership),
      connection_credentials_operation(state, ownership),
      *profile_credentials_operations(state, ownership),
      trunk_operation(state, ownership, 'Sync provider connection metadata'),
      operation_payload('upsert_number', 'PUT', path('numbers', refs[:number_ref]), 'Sync business number metadata', ownership,
                        payload: number_payload(state)),
      operation_payload('update_number_route', 'POST', "#{path('numbers', refs[:number_ref])}/route", 'Sync routing mode', ownership,
                        payload: route_payload(state)),
      *agent_assignment_operations(state, ownership)
    ].compact
  end

  def delete_operations(state, ownership)
    refs = state[:refs] || {}
    [
      *delete_agent_operations(state, ownership),
      *delete_profile_credentials_operations(state, ownership),
      operation_payload('delete_number', 'DELETE', path('numbers', refs[:number_ref]), 'Delete owned inbound number', ownership),
      (unless shared_trunk?(state)
         operation_payload('delete_trunk', 'DELETE', path('trunks', refs[:trunk_ref]), 'Delete owned provider connection only if exclusive',
                           ownership)
       end),
      delete_connection_credentials_operation(state, ownership)
    ].compact
  end

  def trunk_operation(state, ownership, description)
    return if skip_trunk_upsert?(state)

    refs = state[:refs] || {}
    operation_payload('upsert_trunk', 'PUT', path('trunks', refs[:trunk_ref]), description, ownership, payload: trunk_payload(state))
  end

  def connection_credentials_operation(state, ownership)
    connection = (state[:connection] || {}).with_indifferent_access
    refs = (state[:refs] || {}).with_indifferent_access
    credentials_ref = connection[:credentials_ref].presence || refs[:credentials_ref]
    return if credentials_ref.blank? || connection[:password].blank?

    operation_payload(
      'upsert_connection_credentials',
      'PUT',
      path('credentials', credentials_ref),
      'Sync provider connection credentials',
      ownership,
      payload: {
        ref: credentials_ref,
        name: connection_credentials_name(state, connection, credentials_ref),
        username: connection[:username],
        password: connection[:password],
        metadata: ownership_metadata(state).merge(provider_kind: state[:provider_kind], resource_kind: 'provider_connection_credentials')
      }.compact
    )
  end

  def agent_operations(state, ownership)
    [*profile_credentials_operations(state, ownership), *agent_assignment_operations(state, ownership)]
  end

  def profile_credentials_operations(state, ownership)
    Array.wrap(state[:profiles]).flat_map do |profile|
      attrs = profile.with_indifferent_access
      next [] if provider_managed_extension_profile?(state, attrs)
      next [] if attrs[:credentials_ref].blank?

      profile_credentials_operation(state, ownership, attrs)
    end
  end

  def agent_assignment_operations(state, ownership)
    Array.wrap(state[:profiles]).flat_map do |profile|
      attrs = profile.with_indifferent_access
      next [] if provider_managed_extension_profile?(state, attrs)
      next [] if attrs[:agent_ref].blank?

      operation_payload(
        'upsert_agent',
        'PUT',
        path('agents', attrs[:agent_ref]),
        'Sync employee extension assignment',
        ownership,
        payload: {
          ref: attrs[:agent_ref],
          name: agent_name(attrs),
          username: agent_username(attrs),
          agent_aor: attrs[:agent_aor],
          domainRef: attrs[:domain_ref] || attrs[:domainRef],
          domainUri: agent_domain(attrs),
          domain: agent_domain(attrs),
          credentialsRef: attrs[:credentials_ref],
          enabled: attrs[:enabled],
          metadata: ownership_metadata(state).merge(onelink_user_id: attrs[:user_id], internal_extension: attrs[:internal_extension])
        }.compact
      )
    end
  end

  def profile_credentials_operation(state, ownership, attrs)
    return if provider_managed_extension_profile?(state, attrs)

    credentials_ref = attrs[:credentials_ref].presence
    return if credentials_ref.blank? || attrs[:sip_password].blank?

    operation_payload(
      'upsert_agent_credentials',
      'PUT',
      path('credentials', credentials_ref),
      'Sync employee SIP credentials',
      ownership,
      payload: {
        ref: credentials_ref,
        name: profile_credentials_name(attrs, credentials_ref),
        username: attrs[:sip_username],
        password: attrs[:sip_password],
        metadata: ownership_metadata(state).merge(onelink_user_id: attrs[:user_id], internal_extension: attrs[:internal_extension])
      }.compact
    )
  end

  def delete_agent_operations(state, ownership)
    Array.wrap(state[:profiles]).filter_map do |profile|
      attrs = profile.with_indifferent_access
      next if provider_managed_extension_profile?(state, attrs)
      next if attrs[:agent_ref].blank?

      operation_payload(
        'delete_agent',
        'DELETE',
        path('agents', attrs[:agent_ref]),
        'Delete employee extension assignment',
        ownership
      )
    end
  end

  def delete_profile_credentials_operations(state, ownership)
    refs = Array.wrap(state[:profiles]).filter_map do |profile|
      attrs = profile.with_indifferent_access
      attrs[:fonoster_credentials_ref].presence || attrs[:credentials_ref].presence
    end.uniq

    refs.filter_map do |credentials_ref|
      next if credential_ref_used_by_other_sip_profile?(state, credentials_ref)

      operation_payload(
        'delete_agent_credentials',
        'DELETE',
        path('credentials', credentials_ref),
        'Delete employee SIP credentials when no other inbox uses them',
        ownership
      )
    end
  end

  def stale_profile_cleanup_operations(state, ownership)
    Array.wrap(state[:stale_profiles]).flat_map do |profile|
      attrs = profile.with_indifferent_access
      [
        stale_agent_cleanup_operation(state, ownership, attrs),
        stale_profile_credentials_cleanup_operation(state, ownership, attrs)
      ].compact
    end
  end

  def stale_agent_cleanup_operation(state, ownership, attrs)
    agent_ref = attrs[:agent_ref].presence || attrs[:fonoster_agent_ref].presence || attrs[:local_agent_ref].presence
    return if agent_ref.blank? || current_profile_agent_refs(state).include?(agent_ref)

    operation_payload(
      'delete_stale_agent',
      'DELETE',
      path('agents', agent_ref),
      'Delete replaced employee extension assignment',
      ownership
    )
  end

  def stale_profile_credentials_cleanup_operation(state, ownership, attrs)
    credentials_ref = attrs[:credentials_ref].presence || attrs[:fonoster_credentials_ref].presence || attrs[:local_credentials_ref].presence
    return if credentials_ref.blank? || current_profile_credentials_refs(state).include?(credentials_ref)
    return if credential_ref_used_by_other_sip_profile?(state, credentials_ref)

    operation_payload(
      'delete_stale_agent_credentials',
      'DELETE',
      path('credentials', credentials_ref),
      'Delete replaced employee SIP credentials',
      ownership
    )
  end

  def current_profile_agent_refs(state)
    Array.wrap(state[:profiles]).filter_map do |profile|
      attrs = profile.with_indifferent_access
      attrs[:agent_ref].presence || attrs[:fonoster_agent_ref].presence || attrs[:local_agent_ref].presence
    end.uniq
  end

  def current_profile_credentials_refs(state)
    Array.wrap(state[:profiles]).filter_map do |profile|
      attrs = profile.with_indifferent_access
      attrs[:credentials_ref].presence || attrs[:fonoster_credentials_ref].presence || attrs[:local_credentials_ref].presence
    end.uniq
  end

  def normalized_sip_identity(value)
    value.to_s.strip.presence
  end

  def delete_connection_credentials_operation(state, ownership)
    credentials_ref = connection_credentials_ref(state)
    return if credentials_ref.blank?
    return if connection_credentials_used_elsewhere?(state, credentials_ref)

    operation_payload(
      'delete_connection_credentials',
      'DELETE',
      path('credentials', credentials_ref),
      'Delete provider credentials when channel-owned',
      ownership
    )
  end

  def agent_name(attrs)
    attrs[:user_name].presence || attrs[:agent_ref]
  end

  def agent_username(attrs)
    attrs[:internal_extension].presence || attrs[:agent_ref]
  end

  def agent_domain(attrs)
    attrs[:agent_aor].to_s.sub(/\Asip:/i, '').split('@', 2).second.presence
  end

  def provider_managed_extension_profile?(state, attrs)
    provider_kind = state[:provider_kind].to_s
    availability_mode = attrs[:availability_mode].to_s

    return true if provider_kind.in?(PROVIDER_OWNED_ROUTING_KINDS) && PROVIDER_EXTENSION_MODES.include?(availability_mode)
    return true if provider_kind == 'asterisk_analog' && PROVIDER_EXTENSION_MODES.include?(availability_mode)

    false
  end

  def local_native_provider?(state)
    state[:provider].to_s == 'sipuni'
  end

  def connection_credentials_name(state, connection, credentials_ref)
    connection[:name].presence || state[:name].presence || credentials_ref
  end

  def profile_credentials_name(attrs, credentials_ref)
    [
      attrs[:user_name].presence,
      attrs[:internal_extension].presence
    ].compact.join(' ').presence || credentials_ref
  end

  def operation_payload(key, method, path, description, ownership, payload: {})
    return if path.blank?

    risk = ownership[:allowed] ? 'requires_approval' : 'blocked'
    {
      key: key,
      method: method,
      path: path,
      description: description,
      owned: ownership[:allowed],
      shared: false,
      risk: risk,
      payload: sanitized(payload),
      payload_preview: payload_preview_for(key, payload),
      conflict: ownership[:allowed] ? nil : ownership[:conflict]
    }.compact
  end

  def trunk_payload(state)
    refs = state[:refs] || {}
    connection = state[:connection] || {}
    credential_ref = trunk_credentials_ref(state, connection, refs)
    uri = trunk_uri_payload(state, connection)
    {
      ref: refs[:trunk_ref],
      name: connection[:name] || state[:name],
      inboundUri: inbound_uri_for(state, refs),
      sendRegister: connection[:send_register],
      outboundCredentialsRef: credential_ref,
      uris: uri.present? ? [uri] : nil,
      metadata: ownership_metadata(state).merge(provider_kind: state[:provider_kind])
    }.compact
  end

  def trunk_credentials_ref(_state, connection, refs)
    return connection[:fonoster_credentials_ref].presence if connection[:fonoster_credentials_ref].present?
    return unless connection[:password].present? || ActiveModel::Type::Boolean.new.cast(connection[:password_configured])

    connection[:credentials_ref].presence || refs[:credentials_ref].presence
  end

  def trunk_uri_payload(state, connection)
    host = connection[:host].presence
    return if host.blank?

    {
      host: host,
      port: connection[:port],
      transport: connection[:transport].to_s.upcase.presence,
      user: trunk_uri_user(state, connection),
      weight: 1,
      priority: 1,
      enabled: true
    }.compact
  end

  def trunk_uri_user(state, connection)
    return if state[:provider_kind].to_s == 'asterisk_analog'

    connection[:username].presence || state.dig(:phone_numbers, :provider_account_number)
  end

  def inbound_uri_for(state, refs)
    explicit = state.dig(:connection, :inbound_uri).presence || state.dig(:connection, :inboundUri).presence
    return explicit if explicit.present?

    trunk_ref = refs[:trunk_ref].presence
    public_host = ENV['TELEPHONY_VIRTUAL_PBX_PUBLIC_SIP_HOST'].presence ||
                  ENV['TELEPHONY_BRIDGE_PUBLIC_SIP_HOST'].presence ||
                  ENV['FONOSTER_PUBLIC_SIP_HOST'].presence ||
                  public_sip_host_from_bridge_url
    return if trunk_ref.blank? || public_host.blank?

    "#{trunk_ref}.#{public_host}"
  end

  def public_sip_host_from_bridge_url
    host = URI.parse(ENV.fetch('TELEPHONY_BRIDGE_BASE_URL', '')).host
    return if host.blank?

    ip_match = host.match(/(?<ip>\d{1,3}(?:\.\d{1,3}){3})(?:\.sslip\.io)?/)
    return "#{ip_match[:ip]}.sslip.io" if ip_match

    host
  rescue URI::InvalidURIError
    nil
  end

  def number_payload(state)
    refs = state[:refs] || {}
    phone_numbers = state[:phone_numbers] || {}
    {
      ref: refs[:number_ref],
      name: state[:name] || refs[:number_ref],
      telUrl: phone_numbers[:fonoster_tel_url],
      trunkRef: refs[:trunk_ref],
      country: number_country(state),
      countryIsoCode: number_country_iso_code(state),
      city: number_city(state),
      metadata: ownership_metadata(state).merge(
        provider_kind: state[:provider_kind],
        display_phone_number: phone_numbers[:display_phone_number],
        provider_account_number: phone_numbers[:provider_account_number],
        ingress_number: phone_numbers[:ingress_number]
      ).compact
    }.compact
  end

  def route_payload(state)
    refs = state[:refs] || {}
    routing = state[:routing] || {}
    operator_targets = provider_managed_operator_targets(state)
    {
      mode: routing[:bridge_mode] || routing[:mode] || 'operator',
      app_ref: routing[:app_ref] || refs[:runtime_app_ref] || refs[:app_ref],
      metadata: ownership_metadata(state).merge(
        number_ref: refs[:number_ref],
        provider_kind: state[:provider_kind],
        operator_distribution_mode: routing[:operator_distribution_mode],
        routing_controller: routing_controller_for(state),
        media_anchor: 'onelink',
        provider_routing_owner: provider_routing_owner_for(state),
        onelink_role: onelink_role_for(state),
        routeMode: route_mode_metadata_for(state),
        extension_mode: extension_mode_for(state, operator_targets),
        provider_managed_operator_targets: operator_targets.presence,
        display_phone_number: state.dig(:phone_numbers, :display_phone_number),
        provider_account_number: state.dig(:phone_numbers, :provider_account_number),
        ingress_number: state.dig(:phone_numbers, :ingress_number)
      ).compact
    }.compact
  end

  def provider_managed_operator_targets(state)
    Array.wrap(state[:profiles]).map(&:with_indifferent_access).filter_map do |attrs|
      next unless provider_managed_extension_profile?(state, attrs)
      next unless ActiveModel::Type::Boolean.new.cast(attrs.fetch(:enabled, true))

      agent_aor = provider_managed_agent_aor(attrs, state)
      next if agent_aor.blank?

      {
        user_id: attrs[:user_id],
        telephony_sip_profile_id: attrs[:id],
        internal_extension: attrs[:internal_extension],
        sip_username: attrs[:sip_username],
        agent_aor: agent_aor,
        availability_mode: attrs[:availability_mode]
      }.compact
    end
  end

  def provider_owned_routing?(state)
    PROVIDER_OWNED_ROUTING_KINDS.include?(state[:provider_kind].to_s)
  end

  def routing_controller_for(state)
    return 'provider' if provider_owned_routing?(state)

    'onelink_media_bridge'
  end

  def provider_routing_owner_for(state)
    state[:provider_kind] if provider_owned_routing?(state)
  end

  def onelink_role_for(state)
    'sip_device' if provider_owned_routing?(state)
  end

  def route_mode_metadata_for(state)
    'provider_owned_sip_device' if provider_owned_routing?(state)
  end

  def extension_mode_for(state, operator_targets)
    return 'provider_managed' if operator_targets.present?
    return 'browser_webphone' if provider_owned_routing?(state) && browser_webphone_profiles?(state)
    return 'sip_device' if provider_owned_routing?(state)
  end

  def browser_webphone_profiles?(state)
    Array.wrap(state[:profiles]).any? do |profile|
      profile.with_indifferent_access[:availability_mode].to_s == 'browser_webphone'
    end
  end

  def provider_managed_agent_aor(attrs, state)
    return attrs[:agent_aor] if attrs[:agent_aor].present?

    extension = attrs[:internal_extension].presence || attrs[:sip_username].presence
    host = attrs[:sip_host].presence || state.dig(:connection, :host)
    return if extension.blank? || host.blank?

    "sip:#{extension}@#{host}"
  end

  def ownership_metadata(state)
    ownership = state[:ownership] || {}
    {
      managed_by: 'onelink',
      onelink_account_id: ownership[:onelink_account_id] || state[:account_id],
      onelink_inbox_id: ownership[:onelink_inbox_id] || state[:inbox_id],
      onelink_channel_id: ownership[:onelink_channel_id] || state[:channel_id],
      onelink_number_binding_id: ownership[:onelink_number_binding_id],
      onelink_base_url: onelink_base_url
    }.compact
  end

  def onelink_base_url
    ENV['TELEPHONY_BRIDGE_ONELINK_BASE_URL'].presence || ENV['FRONTEND_URL'].presence
  end

  def connection_credentials_ref(state)
    connection = (state[:connection] || {}).with_indifferent_access
    refs = (state[:refs] || {}).with_indifferent_access
    connection[:fonoster_credentials_ref].presence ||
      connection[:credentials_ref].presence ||
      refs[:credentials_ref].presence
  end

  def credential_ref_used_by_other_sip_profile?(state, credentials_ref)
    other_sip_profiles_scope(state)
      .where(
        'credentials_ref = :ref OR fonoster_credentials_ref = :ref OR password_secret_ref = :ref',
        ref: credentials_ref
      )
      .exists?
  end

  def connection_credentials_used_elsewhere?(state, credentials_ref)
    provider_connection_id = state.dig(:resources, :provider_connection_id)
    return true if provider_connection_used_by_other_bindings?(state, provider_connection_id)
    return true if provider_connection_used_by_other_sip_profiles?(state, provider_connection_id)

    Telephony::ProviderConnection
      .where(account_id: account.id)
      .where.not(id: provider_connection_id)
      .where(
        'credentials_ref = :ref OR fonoster_credentials_ref = :ref OR password_secret_ref = :ref',
        ref: credentials_ref
      )
      .exists?
  end

  def other_sip_profiles_scope(state)
    scope = Telephony::SipProfile.where(account_id: account.id)
    inbox_id = state[:inbox_id].presence
    inbox_id.present? ? scope.where.not(inbox_id: inbox_id) : scope
  end

  def provider_connection_used_by_other_bindings?(state, provider_connection_id)
    return false if provider_connection_id.blank?

    Telephony::NumberBinding
      .where(account_id: account.id, provider_connection_id: provider_connection_id)
      .where.not(inbox_id: state[:inbox_id])
      .exists?
  end

  def provider_connection_used_by_other_sip_profiles?(state, provider_connection_id)
    return false if provider_connection_id.blank?

    other_sip_profiles_scope(state)
      .where(provider_connection_id: provider_connection_id)
      .exists?
  end

  def payload_preview_for(key, payload)
    metadata = (payload[:metadata] || {}).with_indifferent_access
    {
      key: key,
      provider_kind: metadata[:provider_kind],
      display_phone_number: metadata[:display_phone_number],
      ingress_number: metadata[:ingress_number],
      remote_mutation: 'requires_approval'
    }.compact
  end

  def apply_remote_actual_conflicts(operations, remote_actual)
    operations.map do |operation|
      next operation if operation[:risk] == 'blocked'

      conflict = remote_actual_conflict_for(operation, remote_actual)
      conflict.present? ? operation.merge(risk: 'blocked', conflict: conflict) : operation
    end
  end

  def remote_actual_conflict_for(operation, remote_actual)
    actual = remote_actual.with_indifferent_access
    return if actual.blank?
    return unless operation[:key].to_s.include?('number')

    metadata = (actual.dig(:number, :metadata) || actual.dig('number', 'metadata') || {}).with_indifferent_access
    return if metadata[:managed_by].blank? || metadata[:managed_by] == 'onelink'

    'remote number exists but is not owned by OneLink'
  end

  def plan_status(operations, ownership)
    return 'requires_manual_reconcile' unless ownership[:allowed]
    return 'requires_manual_reconcile' if operations.any? { |operation| operation[:risk] == 'blocked' }

    'dry_run_valid'
  end

  def remote_mutation_status(ownership)
    ownership[:allowed] ? REMOTE_MUTATIONS_REQUIRES_APPROVAL : REMOTE_MUTATIONS_BLOCKED
  end

  def shared_trunk?(state)
    refs = state[:refs] || {}
    return true if state[:provider_kind].to_s == 'sipuni' && refs[:trunk_ref].to_s == sipuni_trunk_ref

    provider_connection_id = state.dig(:resources, :provider_connection_id)
    provider_connection_used_by_other_bindings?(state, provider_connection_id) ||
      provider_connection_used_by_other_sip_profiles?(state, provider_connection_id)
  end

  def skip_trunk_upsert?(state)
    refs = state[:refs] || {}

    state[:provider_kind].to_s == 'sipuni' && refs[:trunk_ref].to_s == sipuni_trunk_ref
  end

  def sipuni_trunk_ref
    ENV.fetch('TELEPHONY_VIRTUAL_PBX_SIPUNI_TRUNK_REF', DEFAULT_SIPUNI_TRUNK_REF)
  end

  def number_country(state)
    state.dig(:phone_numbers, :country) || ENV.fetch('TELEPHONY_VIRTUAL_PBX_DEFAULT_COUNTRY', 'Kazakhstan')
  end

  def number_country_iso_code(state)
    state.dig(:phone_numbers, :country_iso_code) || ENV.fetch('TELEPHONY_VIRTUAL_PBX_DEFAULT_COUNTRY_ISO_CODE', 'KZ')
  end

  def number_city(state)
    state.dig(:phone_numbers, :city) || ENV.fetch('TELEPHONY_VIRTUAL_PBX_DEFAULT_CITY', 'Almaty')
  end

  def path(resource, ref)
    return if ref.blank?

    "/telephony/#{resource}/#{CGI.escape(ref.to_s)}"
  end

  def sanitized(payload)
    Telephony::VirtualPbx::BridgeResourceClient.sanitize_payload(payload)
  end
end
