# frozen_string_literal: true

require 'cgi'
require 'uri'

class Telephony::VirtualPbx::RemotePlanBuilder
  REMOTE_MUTATIONS_BLOCKED = 'blocked'
  REMOTE_MUTATIONS_REQUIRES_APPROVAL = 'requires_approval'
  DEFAULT_SIPUNI_TRUNK_REF = 'trunk-sipuni-onelink-out'
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
      *sipuni_gateway_operations(state, ownership, 'Prepare Sipuni Asterisk gateway for inbound and outbound calls'),
      sipuni_gateway_credentials_blocker(state),
      operation_payload('update_number_route', 'POST', "#{path('numbers', refs[:number_ref])}/route", 'Apply selected routing mode', ownership,
                        payload: route_payload(state)),
      *agent_assignment_operations(state, ownership)
    ].compact
  end

  def update_operations(state, ownership)
    refs = state[:refs] || {}
    [
      *stale_profile_cleanup_operations(state, ownership),
      *broadcast_sipuni_gateway_cleanup_operations(state, ownership),
      connection_credentials_operation(state, ownership),
      *profile_credentials_operations(state, ownership),
      trunk_operation(state, ownership, 'Sync provider connection metadata'),
      operation_payload('upsert_number', 'PUT', path('numbers', refs[:number_ref]), 'Sync business number metadata', ownership,
                        payload: number_payload(state)),
      *sipuni_gateway_operations(state, ownership, 'Sync Sipuni Asterisk gateway metadata'),
      sipuni_gateway_credentials_blocker(state),
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
      *delete_sipuni_gateway_operations(state, ownership),
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

  def sipuni_gateway_operations(state, ownership, description)
    return [] unless sipuni_gateway?(state)

    sipuni_gateway_payloads(state).filter_map do |payload|
      next if payload[:providerAccountNumber].blank? || payload[:credentialsRef].blank?

      gateway_ref = payload[:gatewayRef] || payload[:ref]
      operation_payload(
        'upsert_sipuni_gateway',
        'PUT',
        path('sipuni-gateways', gateway_ref),
        description,
        ownership,
        payload: payload
      )
    end
  end

  def sipuni_gateway_credentials_blocker(state)
    return unless sipuni_gateway?(state)
    return if sipuni_gateway_payloads(state).any? { |payload| shared_sipuni_gateway_payload?(payload) }

    {
      key: 'missing_sipuni_gateway_credentials',
      method: 'CONFIGURE',
      path: path('sipuni-gateways', (state[:refs] || {})[:number_ref]),
      description: 'Configure explicit Sipuni gateway credentials before remote sync',
      owned: false,
      shared: false,
      risk: 'blocked',
      conflict: 'missing_sipuni_gateway_credentials',
      payload_preview: {
        key: 'missing_sipuni_gateway_credentials',
        provider_kind: 'sipuni',
        remote_mutation: 'blocked'
      }
    }.compact
  end

  def delete_sipuni_gateway_operations(state, ownership)
    return [] unless sipuni_gateway?(state)

    (sipuni_gateway_refs(state) + broadcast_stale_profile_gateway_refs(state)).uniq.filter_map do |gateway_ref|
      operation_payload(
        'delete_sipuni_gateway',
        'DELETE',
        path('sipuni-gateways', gateway_ref),
        'Delete owned Sipuni Asterisk gateway',
        ownership
      )
    end
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
        stale_profile_credentials_cleanup_operation(state, ownership, attrs),
        *stale_sipuni_gateway_cleanup_operations(state, ownership, attrs)
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

  def stale_sipuni_gateway_cleanup_operations(state, ownership, attrs)
    return unless sipuni_gateway?(state)

    stale_sipuni_gateway_refs(state, attrs).filter_map do |gateway_ref|
      operation_payload(
        'delete_stale_sipuni_gateway',
        'DELETE',
        path('sipuni-gateways', gateway_ref),
        'Delete replaced Sipuni Asterisk gateway marker',
        ownership
      )
    end
  end

  def stale_sipuni_gateway_refs(state, attrs)
    refs = (state[:refs] || {}).with_indifferent_access
    number_ref = refs[:number_ref].presence
    extension_ref = attrs[:internal_extension].presence || attrs[:user_id].presence || attrs[:sip_username].presence
    current_refs = sipuni_gateway_refs(state) + current_profile_sip_usernames(state)

    [
      attrs[:sipuni_gateway_ref],
      attrs[:gateway_ref],
      attrs[:gatewayRef],
      attrs[:remote_gateway_ref],
      attrs[:sip_username],
      (number_ref.present? && extension_ref.present? ? [number_ref, extension_ref].join('-') : nil),
      number_ref
    ].compact_blank.uniq.reject { |gateway_ref| current_refs.include?(gateway_ref) }
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

  def current_profile_sip_usernames(state)
    Array.wrap(state[:profiles]).filter_map do |profile|
      profile.with_indifferent_access[:sip_username].presence
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

    return true if provider_kind == 'sipuni' && PROVIDER_EXTENSION_MODES.include?(availability_mode)
    return true if provider_kind == 'asterisk_analog' && PROVIDER_EXTENSION_MODES.include?(availability_mode)

    false
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

  def sipuni_gateway_payloads(state)
    profiles = sipuni_gateway_profiles(state)
    if profiles.present?
      return profiles.map.with_index.filter_map do |profile, index|
        next unless sipuni_gateway_profile_upsertable?(profile)

        sipuni_gateway_payload(state, profile: profile, profile_index: index)
      end
    end

    shared_payload = sipuni_gateway_payload(state)
    return [shared_payload] if usable_shared_sipuni_gateway_payload?(state, shared_payload)

    []
  end

  def usable_shared_sipuni_gateway_payload?(state, payload)
    shared_sipuni_gateway_payload?(payload) && !shared_sipuni_gateway_uses_employee_sip_username?(state, payload)
  end

  def shared_sipuni_gateway_payload?(payload)
    payload[:providerAccountNumber].present? && payload[:credentialsRef].present?
  end

  def shared_sipuni_gateway_uses_employee_sip_username?(state, payload)
    return false if targeted_operator_distribution?(state)

    provider_account_number = normalized_sip_identity(payload[:providerAccountNumber])
    return false if provider_account_number.blank?

    current_profile_sip_usernames(state).filter_map { |username| normalized_sip_identity(username) }.include?(provider_account_number)
  end

  def sipuni_gateway_payload(state, profile: nil, profile_index: nil, target_metadata: profile.present?)
    refs = (state[:refs] || {}).with_indifferent_access
    connection = (state[:connection] || {}).with_indifferent_access
    phone_numbers = (state[:phone_numbers] || {}).with_indifferent_access
    routing = (state[:routing] || {}).with_indifferent_access
    ownership = ownership_metadata(state).with_indifferent_access
    credentials_ref = sipuni_gateway_credentials_ref(state, profile: profile)
    provider_account_number = sipuni_gateway_provider_account_number(state, profile: profile)
    gateway_ref = sipuni_gateway_ref_for(state, profile: profile, profile_index: profile_index)

    {
      ref: gateway_ref,
      gatewayRef: gateway_ref,
      numberRef: refs[:number_ref],
      providerAccountNumber: provider_account_number,
      username: provider_account_number,
      host: connection[:host],
      port: connection[:port],
      transport: connection[:transport],
      credentialsRef: credentials_ref,
      ingressNumber: phone_numbers[:ingress_number],
      displayPhoneNumber: phone_numbers[:display_phone_number],
      appRef: routing[:app_ref] || routing[:runtime_app_ref] || refs[:runtime_app_ref] || refs[:app_ref],
      accountId: ownership[:onelink_account_id],
      inboxId: ownership[:onelink_inbox_id],
      channelId: ownership[:onelink_channel_id],
      callerId: connection[:caller_id] || connection[:callerId],
      metadata: sipuni_gateway_metadata(state, profile: target_metadata ? profile : nil)
    }.compact
  end

  def sipuni_gateway_refs(state)
    profiles = sipuni_gateway_profiles(state)
    return profiles.map.with_index { |profile, index| sipuni_gateway_ref_for(state, profile: profile, profile_index: index) } if profiles.present?

    [(state[:refs] || {}).with_indifferent_access[:number_ref]]
  end

  def broadcast_sipuni_gateway_cleanup_operations(state, ownership)
    return [] unless sipuni_gateway?(state)
    return [] if targeted_operator_distribution?(state)

    broadcast_stale_profile_gateway_refs(state).filter_map do |gateway_ref|
      operation_payload(
        'delete_broadcast_extra_sipuni_gateway',
        'DELETE',
        path('sipuni-gateways', gateway_ref),
        'Delete per-employee Sipuni gateway when operator distribution is broadcast',
        ownership
      )
    end
  end

  def broadcast_stale_profile_gateway_refs(state)
    refs = (state[:refs] || {}).with_indifferent_access
    base_number_ref = refs[:number_ref].presence
    return [] if base_number_ref.blank?

    sipuni_gateway_profiles_for_refs(state).map.with_index.filter_map do |profile, index|
      next if index.zero?

      gateway_ref = sipuni_gateway_ref_for(state, profile: profile, profile_index: index)
      next if gateway_ref.blank? || gateway_ref == base_number_ref

      gateway_ref
    end.uniq
  end

  def sipuni_gateway_ref_for(state, profile:, profile_index: nil)
    refs = (state[:refs] || {}).with_indifferent_access
    number_ref = refs[:number_ref]
    return number_ref if profile.blank? || profile_index.to_i.zero?

    extension = profile[:internal_extension].presence || profile[:user_id].presence || profile[:sip_username]
    [number_ref, extension].compact.join('-')
  end

  def sipuni_gateway_metadata(state, profile: nil)
    metadata = ownership_metadata(state).merge(
      provider_kind: 'sipuni',
      source: 'sipuni_internal_asterisk_gateway',
      routeMode: 'internal_asterisk_gateway'
    )
    return metadata if profile.blank?

    metadata.merge(
      onelink_user_id: profile[:user_id],
      telephony_sip_profile_id: profile[:id],
      target_extension: profile[:internal_extension],
      operator_agent_aor: profile[:agent_aor],
      target_operator_agent_aor: profile[:agent_aor]
    ).compact
  end

  def sipuni_gateway_credentials_ref(state, profile: nil)
    profile = profile.presence
    return profile[:fonoster_credentials_ref].presence || profile[:credentials_ref].presence if profile.present?

    connection = (state[:connection] || {}).with_indifferent_access
    return unless connection[:password].present? || ActiveModel::Type::Boolean.new.cast(connection[:password_configured])

    refs = (state[:refs] || {}).with_indifferent_access
    connection[:fonoster_credentials_ref].presence ||
      connection[:credentials_ref].presence ||
      refs[:credentials_ref].presence
  end

  def sipuni_gateway_provider_account_number(state, profile: nil)
    return profile[:sip_username].presence if profile.present?

    connection = (state[:connection] || {}).with_indifferent_access
    phone_numbers = (state[:phone_numbers] || {}).with_indifferent_access
    connection[:username].presence || phone_numbers[:provider_account_number].presence
  end

  def sipuni_gateway_profiles(state)
    return [] unless targeted_operator_distribution?(state)

    configured_sipuni_gateway_profiles(state)
  end

  def configured_sipuni_gateway_profiles(state)
    profiles = sipuni_gateway_profiles_for_refs(state).select do |attrs|
      attrs[:sip_username].present? &&
        attrs[:credentials_ref].present? &&
        (attrs[:sip_password].present? || attrs[:access_configured] || attrs[:fonoster_credentials_ref].present?)
    end

    profiles.sort_by { |attrs| [attrs[:internal_extension].to_s, attrs[:user_id].to_s, attrs[:sip_username].to_s] }
  end

  def sipuni_gateway_profiles_for_refs(state)
    profiles = Array.wrap(state[:profiles]).map(&:with_indifferent_access).select do |attrs|
      next false if provider_managed_extension_profile?(state, attrs)

      attrs[:internal_extension].present? || attrs[:user_id].present? || attrs[:sip_username].present?
    end

    profiles.sort_by { |attrs| [attrs[:internal_extension].to_s, attrs[:user_id].to_s, attrs[:sip_username].to_s] }
  end

  def targeted_operator_distribution?(state)
    routing = (state[:routing] || {}).with_indifferent_access
    Telephony::RoutingPolicy.normalized_operator_distribution_mode(routing[:operator_distribution_mode]) ==
      Telephony::RoutingPolicy::OPERATOR_DISTRIBUTION_TARGETED
  end

  def sipuni_gateway_profile_upsertable?(profile)
    attrs = profile.with_indifferent_access
    attrs[:sip_password].present? || attrs[:fonoster_credentials_ref].present?
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
    {
      mode: routing[:bridge_mode] || routing[:mode] || 'operator',
      app_ref: routing[:app_ref] || refs[:runtime_app_ref] || refs[:app_ref],
      metadata: ownership_metadata(state).merge(
        number_ref: refs[:number_ref],
        provider_kind: state[:provider_kind],
        operator_distribution_mode: routing[:operator_distribution_mode],
        display_phone_number: state.dig(:phone_numbers, :display_phone_number),
        provider_account_number: state.dig(:phone_numbers, :provider_account_number),
        ingress_number: state.dig(:phone_numbers, :ingress_number)
      ).compact
    }.compact
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

  def sipuni_gateway?(state)
    state[:provider_kind].to_s == 'sipuni'
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
